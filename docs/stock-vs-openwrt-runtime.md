# Stock firmware vs our OpenWrt — runtime comparison

Primary evidence: our own stock dump (`dump-20260919-163622`, git-ignored):
`system-info.txt` (live capture: kernel 3.10.14, modules, interrupts, sysctl,
dmesg, UCI export) and the extracted stock `/etc`. No binary reverse
engineering was needed for these facts; nothing below contains
credentials/calibration contents.

| Feature | Xiaomi stock (observed) | Our OpenWrt 25.12.x | Reason for difference | Measurement required |
| --- | --- | --- | --- | --- |
| Kernel | Linux 3.10.14 (MediaTek SDK, Feb 2023 build) | Linux 6.12.94 (25.12.5) | mainline vs SDK | — |
| Switch/Ethernet | proprietary Ralink ESW/raeth (`ESW:` dmesg lines), swconfig-era | DSA MT7530 + `mtk_eth_soc`, WAN on gmac1, LAN on DSA ports | modern upstream architecture | throughput + err counters |
| NAT fast path | proprietary `hw_nat` module, `net.hwnat.enable=1` | in-tree PPE offload via nftables flowtable (`flow_offloading_hw=1`) | upstream equivalent of the same PPE silicon | PPE entries, A/B throughput |
| PPE health noise | dmesg full of `PpeHitBindForceToCpuHandler … interface with 9 is unkown` (thousands suppressed) and `PpeExtIfRxHandler UnKnown Interface, dev=wl0` | not observed yet | stock PPE bounced some flow class to CPU continuously | check ours stays quiet under same traffic |
| IRQ strategy | **static affinity**: eth0→CPU1, wl0→CPU2, wl1→CPU3; no RPS/XPS anywhere | kernel default (mostly CPU0) + threaded NAPI patch upstream | vendor spreads IRQ load across VPEs | benchmark IRQ affinity variants (experimental only) |
| RPS/XPS | `rps_sock_flow_entries=0`, no per-device rps/xps cpus | `network.globals.packet_steering=0` (conservative default) | both avoid steering; vendor uses affinity instead | A/B only if 200 Mbps target is at risk |
| Conntrack | `nf_conntrack_max=16384` | OpenWrt default for 128 MiB (also 16384) | same scale | stress test near limit |
| QoS | miqos present but `enabled='0'`; `hwnat.switch.miqos='0'`; ifb0/dev_redirect machinery idle | no SQM by default | QoS and PPE fast path conflict; both default off | bufferbloat measurement |
| Firewall | iptables (xt_*: ipset-heavy, `xt_state`, `xt_set`) | firewall4/nftables | modern, safer | — |
| PPPoE | `network.wan.proto='pppoe'` on `eth1`, `mru='1480'`, `ipv6='auto'` | pppoe on `wan` (gmac1), MTU/PMTUD defaults | equivalent | session stability, MSS behavior |
| Wi-Fi drivers | proprietary `mt7603e` (1.6 MB), `mt7615e` (3.7 MB); 5 GHz eeprom from file `/lib/wifi/mt7615e5.eeprom.bin` | mainline mt76 (mt7603/mt7615), EEPROM from Factory nvmem (0x0/0x400, 0x8000/0x4da8) | upstream vs vendor driver | per-client throughput matrix |
| Wi-Fi 5 GHz config | 11ac, bw auto (80), channel auto, `txpwr='max'`, beamforming txbf=3, country CN | no hard-coded country; user sets regdomain; 80 MHz recommended | legal to ship defaults; user's region unknown | channel-selection benchmarking |
| Wi-Fi interfaces | many BSSes (wl0..wl5 seen; guest/AIoT BSSes) | one BSS per radio by default | lean | — |
| CPU clock | `misc.hardware.cpufreq='880MHz'` (stock = rated) | 880 MHz rated, no OC, no voltage change | longevity/stability policy | — |
| Watchdog | kernel watchdog + `/usr/bin/watchdog` userspace | procd hardware watchdog (default OpenWrt) | equivalent | soak confirms no hidden resets |
| Memory footprint | ~30 MB free at capture (many Xiaomi daemons: xiaoqiang, smartvpn, parentalctl, vas, push, otapred, …) | lean base; optional daemons off until configured | fewer proprietary services | baseline RAM comparison |
| IPv6 | `ipv6='auto'` on PPPoE | full odhcp6c/odhcpd stack, PD-capable | OpenWrt IPv6 is more complete | PD test when native v6 exists |
| Diagnostics | closed | collect-*/benchmark-* toolkit, PPE debugfs, conntrack -S, iperf3, tcpdump-mini | observability is a project goal | — |

## Why stock previously showed ~30 Mbps on a 200 Mbps service (hypotheses to test)

Observed constraints from the dump and prior notes: QoS off, CPU mostly idle,
HW NAT present, Wi-Fi errors observed. Candidates, to be isolated during
hardware validation (not assumed):

1. Wi-Fi path errors/retries (stock wl logs showed deauth/reassoc events) —
   test wired first, then per-band.
2. PPE not actually accelerating the tested flow class (force-to-CPU spam) —
   compare `hw_nat` offload counters on stock if it is ever re-measured.
3. ISP-side provisioning/negotiation — ruled in/out by the PPPoE lab test
   (local server) and direct-PC baseline.
4. Ethernet link negotiation issue — check `ESW: Link Status` events and
   negotiated speed on stock vs OpenWrt.

The new firmware must make the bottleneck *observable* (toolkit counters),
not merely claim to remove it.

## What stock demonstrably does that we deliberately keep or reject

- **Keep (concept):** PPE hardware NAT as the primary fast path — but via the
  mainline nftables flowtable implementation, not the SDK module.
- **Keep (concept):** no RPS/packet-steering by default on this SoC class —
  matches our conservative default (and #24307 shows steering is not a fix).
- **Borrow carefully (benchmark only):** vendor IRQ affinity spread
  (eth/wl0/wl1 on separate CPUs). Only an experiment on real hardware, never
  a blind default.
- **Reject:** 3.10 SDK kernel, proprietary drivers, iptables stack, opaque
  daemons, file-based 5 GHz eeprom copy, `txpwr=max` posture.
