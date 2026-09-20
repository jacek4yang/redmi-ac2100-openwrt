# Hardware validation plan (RAM-only first, no flashing)

Current stage: **BUILD-VERIFIED** — nothing in this document has been executed
on hardware. The first physical phase boots the CI-built
`*-initramfs-kernel.bin` from RAM via the stock bootloader. **Power-cycling the
router afterwards returns it to untouched stock firmware** — no NAND write of
any kind is part of this phase.

Stop boundary: every command below is prepared for review. Nothing is executed
until the user explicitly approves the RAM-only test and the physical setup is
confirmed.

## 1. Why RAM-only is safe here

Verified stock boot state (from the dump, `boot-flash-state.txt`):
`boot_wait=on`, `uart_en=1`, `flag_boot_rootfs=0`. The stock U-Boot therefore
pauses for UART input and speaks TFTP. The initramfs image is produced by the
source-build pipeline (validated in CI; see docs/build.md). U-Boot `tftpboot` +
`bootm` load it into RAM and jump to it; flash is never opened for writing.

**Danger note:** the Xiaomi U-Boot UART menu also offers options that load an
image **and write it to flash** (typically menu items "load system code then
write to Flash via TFTP/serial"). Those items are FORBIDDEN in this phase.
Only the command-line interface item (manual `tftpboot` + `bootm`) is used.
Each menu's exact numbering is confirmed on the serial console before
proceeding — never press a menu number from memory.

## 2. Equipment and prerequisites

- 3.3 V USB-UART adapter (CP2102/CH340/FTDI 3.3 V). **Never 5 V or RS-232
  levels.** Connect GND, TX, RX only; never connect VCC. 115200 8N1
  (stock cmdline: `console=ttyS1,115200n8`).
- Ethernet cable from PC to a LAN port; static PC IP on the expected U-Boot
  subnet (confirm via `printenv` — Xiaomi defaults are typically in the
  192.168.31.0/24 range).
- TFTP server on the PC serving the initramfs image
  (`openwrt-ramips-mt7621-xiaomi_redmi-router-ac2100-initramfs-kernel.bin`
  from the source-build artifact; SHA256 verified against `SHA256SUMS`).
- The router's stock firmware must still boot normally before we start
  (baseline sanity).

## 3. Prepared procedure (DO NOT EXECUTE yet)

1. Connect UART; open terminal at 115200 8N1.
2. Power on; interrupt the boot countdown (`boot_wait=on`).
3. At the U-Boot prompt record the environment:
   `printenv` (confirm `ipaddr`, `serverip`, and that no write command is
   armed). Compare against expectations; STOP on surprises.
4. Configure addresses if needed:
   `setenv ipaddr 192.168.31.1; setenv serverip 192.168.31.100`
5. Load the image to RAM:
   `tftpboot <RAMADDR> openwrt-...-initramfs-kernel.bin`
   - `<RAMADDR>`: the uImage is a self-relocating lzma-loader; the exact safe
     download address is confirmed from `printenv`/documentation at the
     console (typical MT7621 practice uses an address in upper RAM such as
     `0x81000000` so the ~8 MB image cannot collide with the decompression
     target at `0x80001000`). UNVERIFIED until the console confirms — treat
     any address in this document as a placeholder, not gospel.
6. Boot it: `bootm <RAMADDR>`
7. Expect Linux to come up to a root shell on the console
   (`Please press Enter to activate this console`).

Rollback: power cycle. Stock firmware boots — nothing was written.

## 4. RAM-boot bring-up checklist (phase-0 hardware truth)

Run through IN ORDER; stop on any mapping/calibration failure and reassess
before continuing. Evidence captured with `scripts/hw/collect-*.sh` into
`/tmp/ac2100-hw/` (initramfs: copy off via `scp` before poweroff).

- [ ] kernel boots; no panic/oops in dmesg
- [ ] 128 MiB RAM detected (`/proc/meminfo` MemTotal ~ 126976 kB)
- [ ] NAND partitions visible read-only (`/proc/mtd` matches documented layout)
- [ ] Factory nvmem cells found (dmesg nvmem/mt76 lines; NO writes)
- [ ] MAC addresses: label MAC on WAN (`gmac1`), base MAC on LAN — compare
      against the router's sticker; mismatch = STOP
- [ ] Ethernet: `wan` link up at 1000/full; `lan1/2/3` each negotiate and pass
      traffic; `ip -s link` shows no error storms
- [ ] MT7530 DSA: `bridge vlan`, per-port counters sane
- [ ] 2.4 GHz (MT7603): phy present, AP starts, client associates
- [ ] 5 GHz (MT7615): phy present, 80 MHz capable, client associates
- [ ] EEPROM/calibration: mt76 loads both EEPROMs from Factory offsets
      (2.4 GHz @ 0x0 size 0x400; 5 GHz @ 0x8000 size 0x4da8 per DTS) —
      tx power/rates look sane; calibration failure = STOP
- [ ] regulatory: `iw reg get` shows a real country after user sets it
      (firmware ships no hard-coded country)
- [ ] DHCP server on LAN works; firewall4 normal
- [ ] flow offload: enable hw offload, pass traffic, confirm PPE entries and
      `conntrack OFFLOAD` flags (`scripts/hw/offload-status.sh`)
- [ ] PPPoE: session against the LAB PPPoE server establishes
- [ ] `scripts/hw/diagnostic-capture-mode.sh enter/exit` round-trips cleanly
- [ ] soak-monitor 30-minute smoke: zero anomalies

## 5. Benchmark methodology (once Level-1/2 pass)

Topology (wired):
```
PC-A (iperf3 server / PPPoE server) ──WAN── RM2100 ──LAN── PC-B (client)
```

- **A/B/C offload:** `benchmark-offload-ab.sh -s <PC-A> -r 5 -t 10 -P "1 4 8"`
  (modes off/sw/hw, state auto-restored). Record throughput, CPU, softirq,
  PPE entries, drops.
- **Latency under load:** `benchmark-latency.sh -H <PC-A> -c 300 -i 0.2`
  concurrently; report min/median/p95/p99/max from `ping-samples.txt`.
- **PPPoE lab reconnects:** `benchmark-pppoe.sh -n 20` against the lab server
  only. Real-ISP cycles need `--live-isp` and stay ≤ 50 with ≥ 20 s spacing.
- **Wi-Fi matrix:** 5 GHz 80 MHz, legal channels in the user's regulatory
  domain (DFS and non-DFS), near-field client first; per-client rows in
  docs/benchmarks.md; 2.4 GHz 20 MHz stability spot-check.
- **Statistics:** ≥ 3 runs per data point (5 for offload A/B); report
  min/median/max; never a single lucky run. Same firmware, same hardware,
  same topology for A/B comparisons.

## 6. Acceptance hierarchy (in order; do not optimize upward out of order)

1. **Level 1 — boot/correctness:** checklist §4 complete, no calibration or
   mapping fault.
2. **Level 2 — wired correctness:** gigabit negotiation on all ports, no
   unexplained drops/errors, PPPoE reliable over 20 lab reconnects.
3. **Level 3 — 200 Mbps production requirement:** sustained PPPoE+NAT ≥
   95 % of the provisioned line (≥ 190 Mbps on an exactly-200 Mbps service)
   with CPU headroom (no single thread pegged) in `hw` mode; engineering
   target is comfortable margin above that, demonstrated in the lab
   independent of ISP speed.
4. **Level 4 — Wi-Fi production requirement:** 5 GHz 80 MHz with a capable
   2x2 AC client sustains the WAN rate (target ≥ 250 Mbps median local TCP
   in a clean channel); RF-limited results classified separately.
5. **Level 5 — stress:** mixed TCP/UDP + Wi-Fi + reconnects stay stable;
   no conntrack/PPE exhaustion pattern (K4 in known-issues).
6. **Level 6 — soak:** staged 30 min → 2 h → 8 h → 24 h → 72 h with zero
   watchdog/OOM/interface-freeze/memory-leak/DNS/Wi-Fi-loss events.
   A stage counts as passed only after it actually ran.
   "Stable" is never claimed from CI or a single boot.

## 7. Soak protocol

`soak-monitor.sh -i 30 -d <stage>` runs the whole stage; background load from
`benchmark-iperf.sh` loops or real usage. Pass criteria per stage:

- zero `anomalies.log` entries (kernel oops/warning/OOM/watchdog/stall,
  err/drop delta > 100/sample, conntrack > 90 %)
- no NETDEV WATCHDOG (K2), no PPE degradation pattern (K4): compare
  `offload-status.sh` at stage start vs end
- memory: no downward MemAvailable trend (plot samples.txt)
- PPPoE session (or lab session) intact at stage end

## 8. What this phase deliberately does NOT do

- no `mtd`, `sysupgrade`, `ubiformat`, `nandwrite`, no flash writes of any kind
- no Factory/Bdata/Bootloader access beyond read-only nvmem by the mt76 driver
- no overclock, no voltage changes
- no regulatory-domain override baked into the image
- no "copy/paste flashing instructions" — those belong to a later, separately
  approved phase with verified backups
