# Firmware landscape: MT7621 / Redmi AC2100 (RM2100)

Evidence survey behind every performance-relevant decision in this project.
Method: pinned-source reads (file/line/commit), our own stock dump, upstream
issue trackers, and clearly-labeled community/anecdotal data. Research date:
2026-09-20. Nothing enters the stable firmware without a row in the technique
matrix at the end.

Evidence classes: **SOURCE** (code/docs read at a pinned commit) ·
**DUMP** (observed in our stock NAND dump) · **ISSUE** (upstream tracker) ·
**ANECDOTAL** (community measurement, uncontrolled).

## 1. Firmware families

### Official OpenWrt (our base)

- Maintenance: active; v25.12.5 (2026-07-01) is the newest 25.12.x — **our pin**.
- Kernel 6.12.94, DSA MT7530, `mtk_eth_soc` with in-tree PPE offload via
  nftables flowtable, mt76 wireless, firewall4/nftables.
- MT7621 PPE: 1 unit, 16384-entry FOE table (`mtk_eth_soc.c` `mt7621_data`,
  `mtk_ppe.h`); nft hookup via `TC_SETUP_FT`; PPPoE offload supported
  (`FLOW_ACTION_PPPOE_PUSH`, single header); IPv6 offload supported
  (5T/3T/6RD/DS-LITE FOE types). **SOURCE**
- WAN is gmac1 direct (not DSA), LAN1-3 are DSA ports 2/3/4; MACs from
  Factory 0xe000/0xe006; MT7603 EEPROM @ Factory 0x0 (0x400), MT7615 @
  0x8000 (0x4da8). **SOURCE**
- Known live issues: see [known-issues.md](known-issues.md) (K1–K7). **ISSUE**

### Xiaomi stock (RM2100 OEM)

- Kernel 3.10.14 MediaTek SDK (Feb 2023 build), iptables, proprietary
  `hw_nat` (PPE offload, `net.hwnat.enable=1`), proprietary `mt7603e` /
  `mt7615e` Wi-Fi, Ralink ESW switch driver. **DUMP**
- Static IRQ affinity: eth0→CPU1, wl0→CPU2, wl1→CPU3; **no RPS/XPS**;
  conntrack 16384; backlog 1000; budget 300; QoS shipped but disabled;
  880 MHz stock clock; kernel+userspace watchdog. **DUMP**
- PPE health noise: thousands of `PpeHitBindForceToCpuHandler … interface
  with 9 is unkown` + `PpeExtIfRxHandler UnKnown Interface, dev=wl0` — some
  flow class kept bouncing to CPU. **DUMP**

### ImmortalWrt

- Active (25.12 branch, ~4–8 week cadence). **ramips/mt7621 code is
  byte-identical to upstream OpenWrt** (same 49 patches, same mtk_eth_soc) —
  no driver-level performance divergence. **SOURCE**
- Real divergence is defaults: `flow_offloading=1` + `flow_offloading_hw=1`
  + nft-fullcone by default (patched firewall4 + `kmod-nft-fullcone`,
  6.12-ready). Their HFO default rides the *same upstream PPE path* we use —
  independent confirmation that enabling HFO is the community-consensus sane
  default for this SoC. **SOURCE**
- No TurboACC/SFE. China packages are feed-only. **SOURCE**

### Lean / coolsnowwolf LEDE

- Active repo, but ramips target is architecturally frozen: **kernel 5.10
  (EOL) + swconfig + fw3/iptables + vendored MediaTek `mtk_hnat`**
  (6.18 only as testing). **SOURCE**
- TurboACC = shell orchestrator over: mainline flow offload, shortcut-fe SFE
  (Qualcomm out-of-tree engine), QCA-ECM, or vendored mtk_hnat debugfs.
  SFE has documented breakage (VPNs, QoS, multi-subnet routing, recurring
  build failures) and **LEDE itself scopes SFE away from ramips**. **SOURCE**
- Full-cone via `xt_FULLCONENAT` (iptables) by default. **SOURCE**

### Padavan 3.4 (hanwckf/rt-n56u)

- **Frozen since 2021-06-14** (still the reference tree, 3.3k★). **SOURCE**
- RM2100 board support: raeth (+QDMA TX, checksum/SG/TSO/TSOv6/HW-VLAN),
  proprietary rt_ppe HW NAT (16K FOE, IPv6, bind threshold 20),
  SFE built but default OFF, RPS/XPS with static IRQ affinity (GMAC→CPU1,
  PCIe radios spread across VPEs), conntrack 16384 on 128 MB, GCC 7,
  `-Os -march=mips32r2 -mtune=1004kc`. **SOURCE**
- Notable: **HW NAT disabled by default on all MT7615 boards**
  (`hw_nat_mode=2`, defaults.c) — vendor-tree Wi-Fi↔PPE conflict. **SOURCE**

### Padavan 4.4 (hanwckf + MeIsReallyBa)

- hanwckf/padavan-4.4: no RM2100 support, last commit 2022-02.
  MeIsReallyBa/padavan-4.4: has RM2100, last commit 2024-01-16. **SOURCE**
- New `mtk_hnat` driver programs the FOE via netfilter hooks —
  architecturally the closest vendor relative of mainline flow offload.
  MT7615 vendor driver v5.1.0.0; HW LRO; QDMA; `xt_FULLCONENAT`. **SOURCE**
- Known issues: Wi-Fi↔HWNAT breakage via `FOE_MAGIC_WLAN` skb tags
  (worked around by disabling `SUPPORT_WLAN_OPTIMIZE`); single-stream
  5 GHz throughput anomalies (#44/#45); conntrack-related crash (#33).
  **ISSUE**

### Community RM2100 builds (surveyed)

- OpenWrt-side (Kwrt, aswifi, marcoavesani, sagehou, Qs315490, …): all are
  package-selection builds on P3TERX-style templates; **none carries
  performance-relevant kernel/driver patches**. **SOURCE**
- Padavan-side: Biaogo94/CleanPadavan-AC2100 (dual profiles; the aggressive
  one: fixed 1000 MHz OC via MPLL poke, `hw_nat_mode=4`, 32K conntrack,
  backlog 2048, userland `-O3`, 72 h soak checklist) and
  mnpo1122/CleanPadavan-AC2100 (4.4 + ~1000 MHz OC). These are catalogs of
  what *not* to copy blindly — and of hypotheses to test. **SOURCE**

## 2. Technique matrix

Classification: **ADOPT** (in the stable firmware now) · **BENCHMARK**
(candidate for hardware A/B before any adoption) · **REJECT** (evidence
against) · **OBSOLETE** (superseded by modern equivalent) · **UNKNOWN**
(insufficient evidence).

| Technique | Source family | Class | Evidence & rationale |
| --- | --- | --- | --- |
| Software flow offload (`flow_offloading=1`) | OpenWrt mainline | **ADOPT** | mainline nft flowtable fast path; ImmortalWrt ships it by default too (SOURCE). Hardware verification still pending (BUILD-VERIFIED stage) |
| Hardware flow offload onto PPE (`flow_offloading_hw=1`) | OpenWrt mainline ≈ SDK hw_nat | **ADOPT** | same 16K-entry PPE silicon the SDK proprietary `hw_nat` programs, driven via mainline `mtk_ppe_offload.c`; PPPoE + IPv6 supported in source; fails soft to sw offload (SOURCE). Vendor ecosystems disable it on MT7615 boards only because of *proprietary Wi-Fi driver* conflicts that do not exist under mt76 (SOURCE); watch the interplay in hardware tests anyway (K4/K6) |
| PPPoE offload on PPE | OpenWrt mainline | **ADOPT** | `FLOW_ACTION_PPPOE_PUSH` + `mtk_foe_entry_set_pppoe` (SOURCE); production WAN is PPPoE; upstream #8837 fixed long ago (ISSUE) |
| packet_steering / RPS via netifd | OpenWrt mainline | **REJECT as default** | open #24307 (25.12.5) TX-watchdog; steering off is also not a fix, only the conservative posture; stock ships no RPS either (DUMP) |
| Static IRQ affinity map (eth→CPUx, radios→CPUy/z) | Padavan 3.4/4.4, Xiaomi stock | **BENCHMARK** | two independent vendor implementations converge on spreading IRQs across VPEs (SOURCE/DUMP); mainline defaults to mostly-CPU0 + threaded-NAPI. A/B on hardware only; never a copied default |
| Conntrack 16384 | stock, Padavan, OpenWrt default | **ADOPT** | three independent defaults converge on 16K for 128 MiB (DUMP/SOURCE) |
| Conntrack 32768 | Padavan aggressive profiles | **BENCHMARK** | only if the many-flows scenario fills 16K (benchmarks.md) |
| `netdev_max_backlog` 2048, `somaxconn` 1024 | Padavan aggressive | **BENCHMARK** | standard sysctls; cheap A/B; stock uses 1000/128 (DUMP) |
| TCP timer profile (fin 40, keepalive 1800/30/5, retries2 5) | Padavan | **BENCHMARK (low priority)** | portable and low-risk, but no identified bottleneck it addresses (§29 test) |
| Full-cone NAT (nft-fullcone / xt_FULLCONENAT) | ImmortalWrt, Lean, Padavan 4.4 | **REJECT for now** | solves NAT-traversal for P2P/gaming, not a throughput feature; not a requirement; adds out-of-tree kmod surface. Revisit only with a user need |
| shortcut-fe / SFE / fast-classifier | Lean TurboACC, Padavan | **REJECT** | out-of-tree engine, documented breakage (VPN/QoS/multi-subnet/build), LEDE itself scopes it away from ramips; mainline flow offload covers the use case (SOURCE) |
| Vendored MediaTek `mtk_hnat` / rt_ppe modules | Lean, Padavan | **OBSOLETE** | same PPE exposed by mainline flow offload on 6.12; porting SDK drivers back would be a maintenance regression (SOURCE) |
| swconfig two-GMAC switch stack | Lean, Padavan 3.4 | **OBSOLETE** | DSA + mtk_eth_soc is the mainline model (SOURCE) |
| Proprietary MT7603/MT7615 Wi-Fi drivers (+ FOE magic tags) | stock, Padavan | **OBSOLETE** | mt76 is the maintained path; the proprietary drivers' PPE hooks are exactly what broke vendor hwnat on MT7615 boards (SOURCE) |
| Wi-Fi→PPE offload (WED-style) | Padavan `hw_nat_mode=4` | **UNKNOWN → measure, not copy** | does not exist on mainline for MT7621 (WED is MT7915+); Wi-Fi↔wired will be CPU-heavier than Padavan mode 4 — with wired NAT on the PPE the CPU headroom should absorb 200 Mbps, but this is the one place Padavan can legitimately win: **measure, don't assume** (SOURCE) |
| QDMA TX / HW VLAN / TSO / SG / checksum as raeth flags | Padavan | **OBSOLETE** | raeth-internal flags; `mtk_eth_soc` implements equivalents via standard netdev features; no flag-level mapping exists to copy (SOURCE). See "QDMA question" in performance.md |
| CPU overclock (900/1000 MHz MPLL pokes) | Padavan builds | **REJECT** | register poke with thermal/longevity cost; stock runs the rated 880 MHz (DUMP); the 200 Mbps target is achievable on the PPE at rated clock |
| Idle downclock (CPU sleep 220 MHz) | Padavan 3.4 option | **UNKNOWN** | not investigated; power is not a stated requirement |
| `-O3` / aggressive userland CFLAGS | Padavan aggressive builds | **REJECT** | forwarding is kernel/PPE-bound; no mechanism for a userland `-O3` NAT win; image-size and stability costs are real (§13) |
| `-march=mips32r2 -mtune=1004kc` | Padavan (GCC 7) | **UNKNOWN (likely moot)** | OpenWrt already builds for mipsel_24kc; a controlled experiment would be allowed but is not prioritized |
| `-Os` vs OpenWrt default | Padavan | **UNKNOWN (likely moot)** | same reasoning |
| HW LRO | Padavan 4.4 raeth | **OBSOLETE** | mainline uses GRO; no evidence GRO is a bottleneck at 200 Mbps |
| HW QoS (`NET_MEDIATEK_HW_QOS`) | Padavan 4.4 | **OBSOLETE** | SQM stays off by default here; if shaping is ever wanted it will be measured software CAKE (with the offload conflict documented) |
| airtime fairness (mt76 default) | OpenWrt mt76 | **ADOPT** | upstream default; keep slow stations from dragging the cell (SOURCE). Note stale #8043 oops report on mt7621 (ISSUE) — watch during Wi-Fi validation |
| 5 GHz 80 MHz + measured channel selection | OpenWrt mt76 | **ADOPT** | standard practice; channel is a measurement, never hard-coded |
| `txpwr=max` posture | stock | **REJECT** | respect regdomain limits; user sets country |

## 3. Net decisions for the stable firmware

1. **Base on official OpenWrt 25.12.5** — nothing in any fork offers a
   maintained MT7621 advantage over mainline; ImmortalWrt's ramips is
   byte-identical anyway (SOURCE).
2. **Fast path = sw + hw flow offload (PPE)** — the only acceleration
   architecture with both mainline support and fork consensus (SOURCE).
3. **Everything else is a benchmark candidate or rejected** — no RPS/affinity
   defaults, no conntrack/sysctl/CFLAG changes, no SQM, no fullcone, no OC.
4. **Hardware validation decides the BENCHMARK rows** per
   [hardware-validation.md](hardware-validation.md) and
   [benchmarks.md](benchmarks.md); results land only as measured data.
