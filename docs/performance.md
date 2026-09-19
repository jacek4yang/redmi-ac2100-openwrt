# Performance

Purpose: the reasoning behind every performance-relevant choice in this
firmware — what is enabled, what is deliberately absent, and what must be
measured before it is believed.

Status: design rationale complete; **no measurements yet**. Numbers land in
[benchmarks.md](benchmarks.md) from real hardware runs only.

## Priorities

1. Reliability and correctness first; throughput second; latency third — in
   that order until [benchmarks.md](benchmarks.md) says otherwise.
2. No cargo cult: every claim below cites upstream documentation/source,
   device-specific dump evidence, or is explicitly marked as requiring
   measurement.

## Fast path: flow offloading and the MT7621 PPE

First boot applies
[../files/etc/uci-defaults/99-redmi-ac2100-tuning](../files/etc/uci-defaults/99-redmi-ac2100-tuning):

- `firewall.@defaults[0].flow_offloading=1` — software flow offload:
  established flows skip per-packet netfilter fast-path work. Option name and
  semantics confirmed in the pinned firewall4 source (`fw4.uc`
  `parse_defaults()` at `PKG_SOURCE_VERSION b6e51575`, the rev pinned by
  v25.12.2).
- `firewall.@defaults[0].flow_offloading_hw=1` — hardware flow offload onto
  the MT7621 PPE (Packet Processing Engine). Evidence at v25.12.2 /
  kernel 6.12.74: the mt7621 kernel config sets `CONFIG_NET_MEDIATEK_SOC=y`,
  which builds `mtk_ppe.o` + `mtk_ppe_offload.o` unconditionally
  (`drivers/net/ethernet/mediatek/Makefile`); `mtk_ppe.c` carries
  MT7621-specific FOE-table code (`IS_ENABLED(CONFIG_SOC_MT7621)` quirk in
  `mtk_ppe_init_foe_table()`); and fw4 emits `flowtable ft { ... flags offload }`
  when the option is set. If the device cannot take hw offload, fw4 logs
  "Hardware flow offloading unavailable, falling back to software offloading"
  and continues on the software path — so this default fails soft.

What this accelerates (upstream-supported; **must be verified on hardware**
per [benchmarks.md](benchmarks.md)):

- routed IPv4, including NAT masquerade;
- PPPoE-encapsulated IPv4 traffic — the PPE path has explicit PPPoE support
  upstream (`mtk_foe_entry_set_pppoe()` in `mtk_ppe.c`;
  `FLOW_ACTION_PPPOE_PUSH` handling in `mtk_ppe_offload.c`, kernel 6.12.74),
  which matters because the production WAN is PPPoE
  ([ipv6-design.md](ipv6-design.md)).

What it does **not** accelerate:

- anything that must remain visible to netfilter per-packet — SQM/qdiscs,
  some VPN tunnel paths;
- IPv6 flow offload behavior on this platform is **not asserted here —
  requires measurement** (and is moot until native IPv6 exists).

Operational check once running: offloaded flows show the `[OFFLOAD]` flag (and
PPE-accelerated flows `[HW_OFFLOAD]`) in `conntrack -L`; the `conntrack`
package ships in the full flavor.

## Why SQM is off — and the correct mental model

SQM (cake/fq_codel) is **not installed** (not in
[../config/packages-full.list](../config/packages-full.list)). Fast path and
shaping are mutually exclusive for the same traffic: a hardware-offloaded
flow never reaches the qdisc, and forcing every packet through the qdisc
forfeits the PPE fast path (upstream flow-offload semantics). The correct
mental model is a **choice**, not a stack:

- default here: fast path (PPE) for maximum routed throughput on an 880 MHz
  dual-core SoC;
- alternative (not shipped): shaping at full CPU cost — justified only by a
  measured bufferbloat problem, which has not been measured yet (see the
  latency-under-load scenario in [benchmarks.md](benchmarks.md)).

## Packet steering: explicitly off

`network.globals.packet_steering='0'` is pinned by the uci-defaults script.
(Unset means off in the netifd implementation — the pin only makes the intent
explicit; LuCI may display/write its own default when its page is saved.)

Evidence at v25.12.2 (all confirmed upstream):

- implementation: `package/network/config/netifd` — `init.d/packet_steering`
  calls `packet-steering.uc`, which writes per-queue
  `rps_cpus`/`rps_flow_cnt` and tasksets threaded-NAPI threads (with an
  `mtk_soc_eth`-specific matcher);
- **current, open upstream bug**: openwrt/openwrt
  [issue #24307](https://github.com/openwrt/openwrt/issues/24307) (2026-07,
  open) — MT7621 `mtk_soc_eth` NETDEV WATCHDOG on TX queue 4 *when packet
  steering is enabled*;
- [issue #18901](https://github.com/openwrt/openwrt/issues/18901) (2025-05,
  open) — packet steering measurably hurts an MT7621 device in the SQM
  scenario.

So: steering **off by default** as a conservative, evidence-backed choice for
this SoC — not a claim that off is universally faster. If benchmarks later
show one core saturated in softirq with steering off, RPS/XPS gets revisited
with data, not folklore.

## IRQ / RPS / XPS stance

Kernel defaults. `irqbalance` is deliberately not installed: there is no
MT7621-specific evidence that it helps, and it adds a daemon plus
non-determinism. During benchmark runs, record `/proc/interrupts` and
`/proc/softirqs` deltas ([benchmarks.md](benchmarks.md)) before touching any
affinity.

## conntrack sizing

Kernel defaults are kept. Raise `net.netfilter.nf_conntrack_max` (sysctl)
**only** when the table actually fills: the symptom is `nf_conntrack: table
full, dropping packet` in `dmesg`, alongside drop/insert_failed counters in
`conntrack -S`. This is candidate tuning, not a default; the many-flows
scenario in [benchmarks.md](benchmarks.md) exists to find out whether the
default suffices.

## GRO / GSO / TSO

Driver defaults are kept. Inspection only: `ethtool -k <iface>` for feature
state, `ethtool -S <iface>` for drop/error counters (recorded during
benchmarks).

## Firewall (fw4 / nftables)

Keep the ruleset lean. With hardware flow offload, established flows bypass
per-packet netfilter cost entirely, so ruleset size matters mostly for
new-flow setup rate. Do not add per-device rules without a measured need.

## Memory budget (128 MiB)

The stock OS sees 124024 kB MemTotal; this firmware targets a lean resident
set. Rough idle footprints — **estimates, to be replaced by `free -m`
measurements** on real hardware:

| Component | Estimate | Note |
| --- | --- | --- |
| LuCI (uhttpd + rpcd + Lua) | ~10–20 MB | pages loaded on demand |
| wpad-basic-mbedtls | ~10 MB | both radios up |
| tailscaled (idle, full flavor) | ~15–25 MB | not started until configured — see [tailscale.md](tailscale.md) |

The point of the table is headroom discipline: on 128 MiB, optional daemons
are opt-in, not default-on.

## Daemons intentionally absent

| Omitted | Reason |
| --- | --- |
| SQM / kmod-sched-cake / luci-app-sqm | conflicts with the hardware-offload fast path (above) |
| irqbalance | no MT7621-specific evidence; measure first |
| samba4 / minidlna / usb-storage | out of scope for a lean router |
| wpad-full / hostapd extras | basic-mbedtls suffices for personal WPA2/WPA3 |

## SmartDNS: installed, not system DNS

smartdns + luci-app-smartdns ship in the full flavor, but **dnsmasq remains
the LAN resolver**; smartdns is not bound into the system DNS path. Evaluate
before enabling: measure resolution latency and correctness with real queries
(`dig` timing from a client, `dnsperf` if available) against dnsmasq. Do not
swap resolvers on benchmark-free enthusiasm.

## Wi-Fi (mt76) performance notes

Both radios use the upstream **mt76** driver (`kmod-mt7603`,
`kmod-mt7615-firmware` per the device profile — confirmed upstream).

- **Airtime fairness**: enabled by default in mt76 upstream (confirmed
  upstream driver default) — keep it; it exists so slow stations do not drag
  the whole cell down.
- **WMM**: required for 802.11n/ac (HT/VHT) rates — never disable it;
  disabling WMM caps clients at legacy rates (802.11 standard behavior).
- **5 GHz**: 80 MHz channels are the sane default for this hardware; pick the
  specific channel by measurement (below).
- **2.4 GHz**: use 20 MHz in crowded spectrum; 40 MHz on 2.4 GHz usually
  hurts neighbors more than it helps you.
- **Channel selection methodology**: scan (`iwinfo wlan0 scan`,
  `iwinfo wlan1 scan`) and survey, choose the least-utilized channel; prefer
  non-DFS unless a DFS channel is measurably cleaner and radar-detect downtime
  is acceptable; benchmark per candidate channel
  ([benchmarks.md](benchmarks.md)). Channel choice is a measurement, not a
  superstition.
- **Regulatory domain**: intentionally unset at first boot (world regdomain).
  Set your own country via LuCI or `uci set wireless.<radio>.country='<CC>'`
  before benchmarking; transmit-power and channel-availability claims require
  the correct regdomain.
- **Power save**: client-side power save trades latency for client battery;
  it is mostly a client property — note it when interpreting Wi-Fi latency
  results.
