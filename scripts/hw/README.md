# scripts/hw — Redmi AC2100 hardware test toolkit

On-router scripts for the hardware-validation phase. Target shell is OpenWrt
`ash` (POSIX); everything degrades gracefully when an optional tool is missing.
**None of these scripts have been run on real hardware yet** — they are staged
for the RAM-only initramfs validation and later flashed deployments
(`docs/hardware-validation.md`).

## Safety model

| Category | Scripts | What they change |
| --- | --- | --- |
| read-only collectors | `collect-system.sh`, `collect-network.sh`, `collect-offload.sh`, `collect-wifi.sh`, `offload-status.sh`, `ac2100-status.sh`, `report.sh` | nothing; write reports to `/tmp` (tmpfs) |
| traffic generators | `benchmark-iperf.sh`, `benchmark-latency.sh` | nothing; send traffic only |
| temporary runtime state | `diagnostic-capture-mode.sh`, `benchmark-offload-ab.sh` | `uci commit firewall` + firewall restart per change, **original state restored on exit/Ctrl-C** |
| WAN cycling | `benchmark-pppoe.sh` | `ifdown`/`ifup wan` per cycle, bounded, wan left up on abort |
| long sampler | `soak-monitor.sh` | nothing; samples counters, flags anomalies |

- No script ever touches MTD/flash layout, UBI, Factory/Bdata, or the bootloader.
- `uci commit` writes a few KB to the jffs2 overlay per call; an A/B session
  costs a handful of such writes — negligible NAND wear, logged each time.
- Results land in `/tmp/ac2100-hw/<timestamp>-<tool>/` (tmpfs, gone on reboot).
  Copy them to the PC with `scp -r root@<router>:/tmp/ac2100-hw .local/hw-results/`.
- **Raw results are never committed to Git** (they can contain client MACs and
  device identity). Only sanitized aggregates go into `docs/benchmarks.md`.
  `.local/hw-results/` is git-ignored.

## Install on the router

```sh
# from the PC, with the repo checked out:
scp -r scripts/hw root@<router>:/root/hw
ssh root@<router> 'chmod +x /root/hw/*.sh'
```

Run each via `sh /root/hw/<name>.sh ...` — no executable bit is strictly needed.

## Lab topology (wired baseline)

```
PC (iperf3 -s)  ──WAN──  Redmi AC2100  ──LAN──  PC (iperf3 -c, ping)
     192.168.2.x/24 or PPPoE server        192.168.1.x/24
```

PPPoE lab: run a PPPoE server (e.g. `rp-pppoe`/`accel-ppp`) on the WAN-side
host so reconnect tests never touch the real ISP line.

## Typical session

```sh
sh /root/hw/collect-system.sh          # baseline captures
sh /root/hw/collect-network.sh
sh /root/hw/collect-offload.sh
sh /root/hw/ac2100-status.sh
sh /root/hw/benchmark-offload-ab.sh -s 192.168.2.10 -r 3 -t 10   # off/sw/hw A/B
sh /root/hw/benchmark-latency.sh -H 192.168.2.10 -c 200 &        # during load
sh /root/hw/soak-monitor.sh -i 30 -d 2h                          # stability
sh /root/hw/report.sh /tmp/ac2100-hw/<dir>                       # summarize (jq)
```

## Packet-capture safety (MT7621 + PPPoE + hardware offload)

Upstream issue **openwrt/openwrt#24459** (OPEN, affects 25.12.5): attaching
tcpdump can hard-reset the router with hardware flow offload enabled, and
capturing on the **underlying ethernet device** crashed *even with offload
disabled*. Therefore:

```sh
sh /root/hw/diagnostic-capture-mode.sh enter          # hw offload off, logged
sh /root/hw/diagnostic-capture-mode.sh capture br-lan 30
sh /root/hw/diagnostic-capture-mode.sh capture pppoe-wan 30 --i-understand-wan-risk
sh /root/hw/diagnostic-capture-mode.sh exit           # original state restored
```

Raw `wan`/`eth*`/DSA-port capture is refused by design. See
`docs/known-issues.md`.
