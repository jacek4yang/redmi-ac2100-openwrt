# Hardware

Purpose: exact hardware identity of the supported device, plus the evidence
behind every component claim.

Status: analysis complete (2026-09-19 stock dump + upstream OpenWrt v25.12.5
sources); no lab measurements yet.

## Model identity

- Product: **Xiaomi Redmi Router AC2100** — the six-antenna Redmi model.
- Board name: `RM2100` — stock reports `misc.hardware.model='RM2100'`, and the
  bootloader contains a `model=RM2100` board check (confirmed from dump).
- OpenWrt device: `xiaomi_redmi-router-ac2100`; DTS compatible
  `xiaomi,redmi-router-ac2100`, model string `Xiaomi Redmi Router AC2100`
  (confirmed upstream).
- This is **not** the Xiaomi Mi Router AC2100 (`xiaomi_mi-router-ac2100`) — a
  different device with a different DTS and different images. See the warning
  in [../README.md](../README.md).

## Components

| Component | Specification | Evidence |
| --- | --- | --- |
| SoC | MediaTek MT7621A, dual-core MIPS 1004Kc V2.15, 2 cores / 4 threads, 880 MHz | confirmed from dump (stock `/proc/cpuinfo`: 4x MIPS 1004Kc V2.15; 880 MHz per stock system info) |
| RAM | 128 MiB DDR3 (124024 kB MemTotal visible to the OS) | confirmed from dump (`/proc/meminfo`; DDR3 per stock system info) |
| NAND flash | 128 MiB; the mtd0 "ALL" window covers 0x0–0x7F80000 (127.5 MiB) | confirmed from dump (`/proc/mtd`, mtd0 size); full layout: [stock-flash-layout.md](stock-flash-layout.md) |
| Ethernet switch | MT7530 gigabit switch, 1x WAN + 3x LAN (`lan1`-`lan3` on switch ports 2-4, `wan` on gmac1) | confirmed upstream (v25.12.5 `mt7621_xiaomi_router-ac2100.dtsi` `&switch0`/`&gmac1`) |
| Wi-Fi 2.4 GHz | MediaTek MT7603EN (802.11n, 2 spatial streams — chip capability); on `pcie1`, EEPROM from Factory offset 0x0000 (signature `0x7603`) | confirmed from dump (Factory signatures) + upstream (`kmod-mt7603` in device profile; v25.12.5 dtsi `&pcie1` nvmem `eeprom_factory_0`, freq-limit 2.4-2.5 GHz) |
| Wi-Fi 5 GHz | MediaTek MT7615N (802.11ac, 4 spatial streams — chip capability); on `pcie0`, EEPROM from Factory offset 0x8000 (signature `0x7615`) | confirmed from dump (Factory signatures) + upstream (`kmod-mt7615-firmware` in device profile; v25.12.5 dtsi `&pcie0` nvmem `eeprom_factory_8000`, freq-limit 5-6 GHz) |
| Antennas | 6 external antennas | product identity of the RM2100 model |
| LEDs | status amber (GPIO 6), status white (GPIO 8), WAN amber (GPIO 10), WAN white (GPIO 12) | confirmed upstream (DTS) |
| Button | reset (GPIO 18) | confirmed upstream (DTS) |
| Serial console | ttyS1, 115200 8n1; enabled in stock env (`uart_en=1`) | confirmed from dump (kernel cmdline `console=ttyS1,115200n8`, boot flags) |
| Bootloader | uImage-wrapped U-Boot 1.1.3 (build 2020-09-21 11:47:48Z), load/entry 0xA0200000 | confirmed from dump (uImage header parse + string analysis) |

## Stock software snapshot (reference)

- Base: OpenWrt 18.06-SNAPSHOT, `DISTRIB_TARGET=ramips/mt7621`, arch
  `mipsel_24kc` (confirmed from dump, `etc/openwrt_release`).
- Kernel: `Linux XiaoQiang 3.10.14 #0 SMP Mon Feb 13 12:40:43 2023 mips`
  (confirmed from dump).
- UI: LuCI with the Xiaomi `xiaoqiang` theme (confirmed from dump).
- Notable binary: `bin/ated`, a factory ATE engineering daemon with a UDP
  control channel that can spawn processes — security-relevant; details in
  [stock-flash-layout.md](stock-flash-layout.md#stock-rootfs-findings).

## Not confirmed — and why it does not matter

| Open question | Status | Why it is irrelevant here |
| --- | --- | --- |
| Exact RAM chip part numbers | not read out | image selection depends only on the device profile, never on the RAM vendor |
| Exact NAND chip part number | not identified | both stock and OpenWrt layouts are fixed per model; the MTK NAND driver abstracts the chip |
| PCB revision | not recorded | no revision-specific DTS variants exist upstream for this device |
