# Known issues register

Tracked issues that can affect this firmware on the Redmi AC2100 (MT7621,
OpenWrt 25.12.x, kernel 6.12). Every entry states evidence, our exposure, and
what hardware validation must check. Statuses verified 2026-09-20 against the
GitHub API.

## K1 — tcpdump/packet capture can hard-reset the router (hw flow offload + PPPoE)

- **Status:** OPEN upstream, unfixed in 25.12.5 (kernel 6.12.94)
- **Evidence:** [openwrt/openwrt#24459](https://github.com/openwrt/openwrt/issues/24459)
  (TP-Link ER605 v2, ramips/mt7621; reproduced on 24.10.5 and 25.12.5).
  Watchdog reset seconds–1 min after attaching tcpdump. Test matrix in the
  report: `pppoe-wan` + `flow_offloading_hw=1` → crash; `pppoe-wan` + hw
  offload off → stable; **underlying ethernet device → crash even with hw
  offload off**. Root cause not established (shape matches tunnel-encap + PPE
  + packet socket; cross-ref [#20869](https://github.com/openwrt/openwrt/issues/20869),
  L2TP encap panic on filogic, also OPEN).
- **Our exposure:** identical SoC/driver stack; WAN is PPPoE in production.
- **Mitigation:** `scripts/hw/diagnostic-capture-mode.sh` — disables hw
  offload before capture, refuses raw WAN/ethernet interfaces, restores
  state afterwards. Normal operation keeps hw offload ON.
- **Hardware validation required:** confirm `enter → capture pppoe-wan → exit`
  survives a capture under load on RM2100 specifically.

## K2 — NETDEV WATCHDOG TX queue timeout (mtk_soc_eth)

- **Status:** OPEN
- **Evidence:** [openwrt/openwrt#24307](https://github.com/openwrt/openwrt/issues/24307)
  (Archer C6 v3, 25.12.5 / 6.12.94). Discussion points to an architectural
  race (16 netdev TX queues over one shared QDMA tx_ring, BQL accounting).
  Reporter confirmed **`packet_steering=0` is NOT a reliable workaround**
  (recurred after days).
- **Our exposure:** same driver. Unknown frequency on RM2100.
- **What we watch:** soak test asserts no "NETDEV WATCHDOG" lines in dmesg;
  `soak-monitor.sh` flags watchdog/stall patterns.

## K3 — MT7621/MT7530 RX/NAPI overload after upstream link failure

- **Status:** OPEN, labeled `release/25.12` (filed 2026-09-13)
- **Evidence:** [openwrt/openwrt#25162](https://github.com/openwrt/openwrt/issues/25162) —
  extreme softirq CPU and LAN loss after an upstream link flap on a DSA port;
  reproducible with both sw and hw offload disabled.
- **Our exposure:** WAN is on gmac1 (not a DSA port on this DTS), LAN is DSA;
  a flapping WAN-side switch could plausibly trigger the same path.
- **What we watch:** soak + link-flap test; `/proc/softirqs` deltas.

## K4 — Hardware NAT offload silently degrades after uptime

- **Status:** OPEN since 2022
- **Evidence:** [openwrt/openwrt#10354](https://github.com/openwrt/openwrt/issues/10354) —
  hw NAT offload stops working after uptime; one core pegged; throughput caps
  around ~200 Mbps.
- **Our exposure:** direct — this is exactly our production path (and
  suspiciously close to the ~200 Mbps symptom class).
- **What we watch:** soak compares PPE entry count + `conntrack OFFLOAD` count
  + throughput at start vs end; `offload-status.sh` snapshots in soak output.

## K5 — hw flow offload breaks long-lived UDP flows (e.g. WireGuard)

- **Status:** OPEN (triage-bot labeled `invalid`, substantively unresolved)
- **Evidence:** [openwrt/openwrt#17915](https://github.com/openwrt/openwrt/issues/17915) —
  conntrack/flowtable aging bug stalls long-lived UDP tunnels.
- **Our exposure:** Tailscale (WireGuard-based) in the full flavor.
- **What we watch:** Tailscale direct-connection session longevity during
  hardware tests; if hit, evaluate excluding the tunnel port from offload.

## K6 — mt7615 client-specific slowness (~3 Mbps for some clients)

- **Status:** OPEN since 2021; Redmi AC2100 explicitly mentioned
- **Evidence:** [openwrt/mt76#561](https://github.com/openwrt/mt76/issues/561);
  related: [#1058](https://github.com/openwrt/mt76/issues/1058) (low 5 GHz
  signal on mt7621+mt7615, 2026-02), [#1129](https://github.com/openwrt/mt76/issues/1129)
  (external-PA TX clamped at 9 dBm on some units, 2026-09).
- **Our exposure:** the 5 GHz radio is a production path for the 200 Mbps WAN.
- **What we watch:** per-client throughput matrix during Wi-Fi validation;
  classify RF-environment vs client-specific failures separately
  (docs/benchmarks.md).

## K7 — MT7530 100 Mbit link autonegotiation failure

- **Status:** OPEN since kernel 6.6 era
- **Evidence:** [openwrt/openwrt#15348](https://github.com/openwrt/openwrt/issues/15348) —
  link negotiates 1 G but passes no traffic with some 100 Mbit peers; forced
  speed works around it.
- **Our exposure:** any 100 Mbit LAN device.
- **What we watch:** link validation includes a 100 Mbit client if available.

## K8 — Source Buildroot images are not bit-for-bit reproducible

- **Status:** root cause identified (2026-09-20); not a defect, no action
- **Evidence:** per-file squashfs comparison of two clean source-build runs
  (35452208528 vs 35460747904, same pinned commit/config): 1201 rootfs
  entries, **zero path diffs, zero metadata diffs** (mtimes normalized),
  exactly **five content diffs**:
  1. `/etc/apk/keys/public-key.pem` — fresh EC P-256 keypair per build tree
     (`rules.mk:295-297`: `BUILD_KEY_APK_PUB=$(TOPDIR)/public-key.pem`; each
     clean CI clone generates a new `key-build`),
  2. `/lib/apk/db/installed`, 3. `/lib/apk/db/scripts.tar.gz` — apk database
     entries tied to that key,
  4. `/usr/bin/apk` — exactly 2 differing bytes (gzip mtime of an embedded
     archive member),
  5. `/usr/lib/libnftables.so.1.1.0` — build-stamp variance, **fixed upstream
     by `8be3ba900e` (25.12.3+, i.e. in our current 25.12.5 pin)**.
- **Interpretation:** image content is deterministic except for the per-build
  apk signing key (by design, signs locally-built packages) and a 2-byte
  timestamp. `kernel1` is bit-for-bit reproducible across runs; the
  ImageBuilder pipeline is bit-for-bit reproducible end-to-end.
- **Our exposure:** auditability nuance only; no functional impact.
- **Remaining action:** none required. If full source-path bit-reproducibility
  is ever wanted, the path is pinning/reusing `key-build` — deliberately not
  done (a pinned signing key in a public repo would be worse, not better).

## K9 — Historical (closed upstream, listed for completeness)

- [#8837](https://github.com/openwrt/openwrt/issues/8837) PPPoE hw offload broken — fixed (works since 5.10; closed 2026-04)
- [#10572](https://github.com/openwrt/openwrt/issues/10572) IPv6 hw offload panic — closed 2022-11
- [#11756](https://github.com/openwrt/openwrt/issues/11756) ppe0 debugfs panic — fixed 2023
- [#8043](https://github.com/openwrt/openwrt/issues/8043) airtime-fairness oops on mt7621 — OPEN but stale; airtime fairness is not enabled in our defaults

## Standing caveats (not bugs)

- **Hardware validation has not happened yet.** Everything in this repository
  is BUILD-VERIFIED only (README stability stage). No runtime claim — including
  hw offload engaging, PPE entries binding, or Wi-Fi throughput — is proven
  until the RAM-only and flashed test phases complete.
- **cake_mq low throughput** ([openwrt/openwrt#22344](https://github.com/openwrt/openwrt/issues/22344),
  listed as a 25.12 known issue): only relevant if SQM is ever enabled; our
  default keeps SQM off (docs/performance.md).
