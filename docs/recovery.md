# Recovery

Purpose: the architecture-level map of how this router boots, what safety nets
exist in principle, and what backups are in hand — **without any procedures**.

Status: architecture analysis complete. **No recovery path has been validated
on this unit, and this repository has never flashed the router.** Flashing and
recovery procedures are deliberately omitted until they are validated on
hardware.

> **Model warning.** This page describes the **Xiaomi Redmi Router AC2100**
> (RM2100, six antennas). The **Xiaomi Mi Router AC2100** is a different
> device with a different DTS and image layout; nothing here transfers to it.

## Boot chain (stock, as dumped)

1. BootROM (MT7621 ROM) loads the bootloader from NAND.
2. mtd1 **Bootloader**: uImage-wrapped **U-Boot 1.1.3** (built 2020-09-21
   11:47:48Z, load/entry 0xA0200000) with the MT7621 stage1, the MTK NAND
   driver, a `model=RM2100` board check, `tftpboot`/`bootm` support, and the
   dual-image environment flags (confirmed from dump).
3. U-Boot selects **kernel0 or kernel1** per `flag_boot_rootfs` (0 = kernel0 +
   rootfs0 active at dump time; the encoding is hypothesis, consistent with
   observation), with failure bookkeeping in `flag_try_sys1_failed`,
   `flag_try_sys2_failed` and `flag_boot_success` (semantics: hypotheses).
4. The kernel mounts the rootfs from UBI (ubi0 volume `ubi_rootfs`, raw
   squashfs via `/dev/mtdblock14`) (confirmed from dump).

What the dual-image design implies (hypotheses, marked): two kernel/rootfs
pairs plus try/fail flags exist so an OTA can write the *inactive* pair, flip
the boot flag, and fall back automatically if the new system fails to boot.
At dump time kernel0 and kernel1 held byte-identical payloads — the fallback
slot was last refreshed by the same build (confirmed from dump).

## Backups that exist

The 2026-09-19 dump (`dump-20260919-163622/`) is a full NAND read including
`mtd0-ALL.bin`:

- every **static** partition (Bootloader, Config, Bdata, Factory, crash,
  crash_syslog, kernel0, kernel1, rootfs0, rootfs1, obr, ubi_rootfs) verified
  **byte-for-byte** between router-side and local copies (confirmed from dump:
  `verify.csv`, `README-DUMP.txt`);
- `mtd0`, `cfg_bak` and `overlay` legitimately differ between dump passes
  (runtime-writable); `mtd15`/`data` is a busy UBI view, covered through its
  backing partition.

Keep copies **off the device and off a single disk**. Dumps are git-ignored by
design and must never be published: they contain credentials, MAC addresses,
the board serial number, and unit-unique calibration data (policy:
[stock-flash-layout.md](stock-flash-layout.md#sensitive-data-policy)).

### Why the Factory and Bdata backups are critical

- **Factory** holds the unit-unique MT7603/MT7615 radio calibration and the
  assigned MAC addresses (exposed as nvmem cells by the upstream DTS). It
  cannot be regenerated: a lost Factory means permanently degraded Wi-Fi and
  lost MAC addresses.
- **Bdata** holds the board serial number and identity data.
- Both have verified backups in the dump, both are read-only in the OpenWrt
  layout, neither must ever be erased — and their contents must never be
  published.

## How OpenWrt v25.12.5 uses the flash (confirmed upstream)

- Stock **kernel0 is preserved** in place as `kernel_stock`
  (0x200000–0x600000).
- OpenWrt's kernel goes into the former **kernel1** slot (`kernel`,
  0x600000–0xA00000).
- A single `ubi` partition spans 0xA00000–0x7F80000, repurposing stock
  rootfs0 + rootfs1 + overlay + obr.

Full tables: [stock-flash-layout.md](stock-flash-layout.md#how-openwrt-v25122-maps-onto-the-same-nand).

## Recovery options inventory (concept level; none validated on this unit)

| Option | Basis | Validation state |
| --- | --- | --- |
| OpenWrt failsafe mode | standard upstream OpenWrt feature: boot-time button window, read-only rootfs | not yet validated on this unit |
| initramfs netboot | `*-initramfs-kernel.bin` is a RAM-only image; the stock U-Boot contains `tftpboot` and `bootm`, and `boot_wait=on` + `uart_en=1` make the console interactive at boot (confirmed from dump) | not yet validated on this unit |
| UART console | ttyS1, 115200 8n1; `uart_en=1` in the stock environment (confirmed from dump) | not yet validated on this unit |
| Xiaomi stock recovery | the stock firmware contains a recovery mechanism (`misc.hardware.recovery` observed) | not yet validated on this unit |

Until each row is exercised on real hardware, treat this table as a map of
what should exist — not as instructions.

## Known hardware risks

- **NAND bad blocks**: one known bad PEB in the stock overlay region, which
  lies inside the future OpenWrt `ubi` span. Absorbing bad blocks is UBI's
  core job, but the bad-block count is a live property of the chip — check it
  before and after any future flash operation (confirmed from dump: ubi1 PEB
  scan).
- **Wear**: the overlay region showed a maximum erase counter of 31 at dump
  time (modest); ubi0 was essentially unworn (max erase counter 1).
- **rootfs1 is partially UBI-formatted** (102/208 PEBs; hypothesis: orphaned
  OTA target). Irrelevant once OpenWrt's `ubi` partition reformats the span,
  but a reminder that the stock OTA machinery left debris.

## Explicit non-goals of this document

No flash commands, no U-Boot environment edits, no step-by-step recovery
procedures — by design, until validated on hardware. Anyone who needs
procedures today should treat the device as unrecoverable-by-this-repository
and rely on the off-device backups.
