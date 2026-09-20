# Stock flash layout

Purpose: the authoritative reference for the RM2100 stock NAND layout, its UBI
structure, the bootloader and boot flags, and how OpenWrt v25.12.5 maps onto
the same flash.

Status: confirmed from the 2026-09-19 dump (all static partitions verified
byte-for-byte router-vs-local); boot-flag semantics are hypotheses where
marked.

> **Model warning.** Everything on this page describes the **Xiaomi Redmi
> Router AC2100** (RM2100, six antennas). The **Xiaomi Mi Router AC2100** is a
> different device with a different DTS and image layout; none of this
> transfers to it.

## Evidence base and reproduction

All structural facts below come from `dump-20260919-163622/`, produced by the
read-only inspector [../scripts/inspect-stock.ps1](../scripts/inspect-stock.ps1):

```
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\inspect-stock.ps1 -DumpDir dump-20260919-163622
```

The script verifies file sizes against the stock `/proc/mtd` table, sniffs
uImage / UBI / squashfs formats, parses uImage headers, proves dump
self-consistency by hashing every partition against the matching byte range of
`mtd0-ALL.bin`, and redacts sensitive partitions by design (it classifies them
structurally and never prints contents).

Verification state (dump `verify.csv` / `README-DUMP.txt`): every static
partition matched byte-for-byte between router-side and local copies.
`Match=False` appears only for `mtd0`, `cfg_bak` and `overlay`, which are
writable at runtime and legitimately drift between the two dump passes.
`mtd15` ("data") is a busy UBI view and was not raw-dumped.

## Physical partition table (stock `/proc/mtd`)

Erase block size is 0x20000 (128 KiB) throughout; offsets were confirmed by
mtd0 slice hashing. The partitions tile mtd0 exactly. The last 512 KiB of the
128 MiB chip lie outside the "ALL" window (hypothesis: NAND bad-block table /
factory-reserved region).

| mtd | Name | Offset | Size | Role (observed) |
| --- | --- | --- | --- | --- |
| mtd0 | ALL | 0x0000000 | 0x7F80000 (127.5 MiB) | whole-chip window containing all partitions below |
| mtd1 | Bootloader | 0x0000000 | 0x80000 (512 KiB) | uImage-wrapped U-Boot 1.1.3 (see below) |
| mtd2 | Config | 0x0080000 | 0x40000 (256 KiB) | Xiaomi config store (contents redacted) |
| mtd3 | Bdata | 0x00C0000 | 0x40000 (256 KiB) | Xiaomi board data incl. serial number (contents redacted) |
| mtd4 | Factory | 0x0100000 | 0x40000 (256 KiB) | radio calibration / EEPROM + MACs (see below) |
| mtd5 | crash | 0x0140000 | 0x40000 (256 KiB) | 100% 0xFF — empty, no crash data |
| mtd6 | crash_syslog | 0x0180000 | 0x40000 (256 KiB) | 100% 0xFF — empty |
| mtd7 | cfg_bak | 0x01C0000 | 0x40000 (256 KiB) | Xiaomi config backup, runtime-writable |
| mtd8 | kernel0 | 0x0200000 | 0x400000 (4 MiB) | stock kernel slot A |
| mtd9 | kernel1 | 0x0600000 | 0x400000 (4 MiB) | stock kernel slot B |
| mtd10 | rootfs0 | 0x0A00000 | 0x1A00000 (26 MiB) | UBI (ubi0); active rootfs at dump time |
| mtd11 | rootfs1 | 0x2400000 | 0x1A00000 (26 MiB) | partially UBI-formatted; see below |
| mtd12 | overlay | 0x3E00000 | 0x2600000 (38 MiB) | UBI (ubi1); runtime-writable data |
| mtd13 | obr | 0x6400000 | 0x1B80000 (27.5 MiB) | fully UBI-formatted, unused at runtime; see below |

### Logical (gluebi) views — not physical partitions

| mtd | Name | Size | Backs |
| --- | --- | --- | --- |
| mtd14 | ubi_rootfs | 0xC1C000 (12,697,600 B) | ubi0 volume 0 (100 LEBs x 124 KiB) |
| mtd15 | data | 0x21E8000 (35,553,280 B) | ubi1 volume 0 (280 LEBs x 124 KiB) |

These exist because the stock kernel attaches gluebi to expose UBI volumes as
mtdblock devices (confirmed from dump: `/sys/class/ubi`, sizes match the LEB
math exactly). They do not appear in the mtd0 tiling.

## UBI structure

LEB size is 124 KiB (126,976 B, per sysfs `eraseblock size`) on 128 KiB PEBs.

| UBI device | Attached mtd | Geometry | Volumes | Notes |
| --- | --- | --- | --- | --- |
| ubi0 | mtd10 (rootfs0) | 208 LEBs; max erase counter 1 | vol 0 `ubi_rootfs`: 100 LEBs = 12,697,600 B; 84 LEBs free | volume holds a **raw squashfs** (magic `hsqs`), mounted as `/` read-only via `/dev/mtdblock14` (confirmed from dump) |
| ubi1 | mtd12 (overlay) | 304 PEBs total, 303 with EC headers, **1 bad PEB**; max erase counter 31 | vol 0 `data`: 280 LEBs, UBIFS | mounted rw at `/etc`, `/data`, `/userdisk` (confirmed from dump) |

- **rootfs1** (mtd11): only 102 of 208 PEBs carry UBI EC headers — partially
  formatted (hypothesis: written once by an OTA update, then orphaned when the
  boot flags moved back to the other slot).
- **obr** (mtd13): fully UBI-formatted (220/220 PEBs) but not attached or
  mounted at runtime (hypothesis: OEM backup/recovery store).
- **NAND wear note**: one known bad PEB in the overlay region and a maximum
  erase counter of 31 there; ubi0 is essentially unworn (max EC 1). Absorbing
  bad blocks is UBI's core job; see [recovery.md](recovery.md) for why this
  matters.

## Dual-kernel slots and boot flags

kernel0 and kernel1 contain **byte-identical uImage payloads** (`MIPS OpenWrt
Linux-3.10.14`, data size 3,053,588 B, load 0x81001000, entry 0x813F9F00,
built 2023-02-13 12:40:43Z, header CRC ok); the slots differ only in
post-image padding (confirmed from dump).

Boot flags observed in NVRAM at dump time (values confirmed from dump;
semantics hypotheses where marked):

| Flag | Value | Meaning |
| --- | --- | --- |
| `flag_boot_rootfs` | 0 | selects the active kernel+rootfs pair; 0 = kernel0 + rootfs0 (encoding is hypothesis, consistent with rootfs0 being the mounted `/`) |
| `flag_boot_type` | 2 | boot mode marker (hypothesis) |
| `flag_ota_reboot` | 0 | OTA-in-progress marker (hypothesis) |
| `flag_last_success` | 0 | last-boot outcome bookkeeping (hypothesis) |
| `flag_boot_success` | 1 | current system booted successfully (hypothesis) |
| `flag_try_sys1_failed` | 0 | failure counter for slot 1 (hypothesis: dual-image fallback bookkeeping) |
| `flag_try_sys2_failed` | 0 | failure counter for slot 2 (hypothesis) |
| `boot_wait` | on | U-Boot boot-delay window, console interrupt possible (confirmed present in bootloader strings) |
| `uart_en` | 1 | serial console enabled; also on the kernel cmdline (confirmed from dump) |

The dump's NVRAM also contains sensitive values (e.g. a system password
hash). They exist; they are never reproduced anywhere in this repository (see
*Sensitive-data policy* below).

Kernel cmdline (confirmed from dump): `console=ttyS1,115200n8 ... uart_en=1
factory_mode=0`.

## Bootloader (mtd1)

Confirmed from dump (uImage header parse + string analysis via
inspect-stock.ps1):

- U-Boot **1.1.3**, built 2020-09-21 11:47:48Z, wrapped in a uImage with
  load/entry **0xA0200000**.
- Contains the MT7621 stage1, the MTK NAND driver, and a `model=RM2100` board
  check.
- Contains the dual-image environment flags (`flag_boot_rootfs`,
  `flag_boot_recovery`, `boot_wait`, and the try/fail counters above).
- Contains `tftpboot` and `bootm` support; with `boot_wait=on` and `uart_en=1`
  the console is interactive at boot. Recovery implications:
  [recovery.md](recovery.md).

## Factory and Bdata: calibration and identity

- mtd4 **Factory** carries the unit-unique radio calibration/EEPROM: the
  MT7603 block at offset 0x0000 and the MT7615 block at offset 0x8000
  (signature words `0x7603` / `0x7615` confirmed from dump; the partition is
  99.54% erased otherwise).
- The OpenWrt DTS exposes exactly these regions as nvmem cells `eeprom@0` and
  `eeprom@8000`, plus MAC cells `macaddr@e000` / `macaddr@e006` (confirmed
  upstream); the mt76 driver reads calibration and MAC addresses from here at
  probe time.
- **Factory must never be erased or overwritten.** Calibration data is
  unit-unique and cannot be regenerated; losing it permanently degrades or
  breaks Wi-Fi and loses the assigned MAC addresses. The 2026-09-19 dump
  contains a verified copy — keep it off the device (see
  [recovery.md](recovery.md)).
- mtd3 **Bdata** is the Xiaomi board-data blob (binary header followed by
  `SN=...`; contents redacted) — board serial number and identity data.
- Calibration values, MAC addresses and serial numbers are **never
  published** — not in docs, not in git.

## Stock rootfs findings

- ubi0 vol 0 is a raw squashfs holding the stock system: OpenWrt
  18.06-SNAPSHOT base, kernel `Linux XiaoQiang 3.10.14`, LuCI with the
  `xiaoqiang` theme (confirmed from dump).
- The rootfs ships `bin/ated`: a 12 KB MIPS32r2 musl ELF. Static analysis with
  reverse-mcp (IDA 9.2 idalib MCP server) shows imports
  `socket/bind/recvfrom/sendto/select` plus `fork/execvp/dup2/kill` — a UDP
  engineering-test daemon capable of spawning processes (factory ATE agent).
  Security-relevant: an unauthenticated process-spawning control channel is
  exactly the kind of stock leftover that must not persist — one more reason
  stock firmware should not stay on the device.

## How OpenWrt v25.12.5 maps onto the same NAND

From `mt7621_xiaomi_redmi-router-ac2100.dts` (which includes
`mt7621_xiaomi_router-ac2100.dtsi`, which includes
`mt7621_xiaomi_nand_128m.dtsi`) — confirmed upstream:

| OpenWrt partition | Offset range | Notes vs stock |
| --- | --- | --- |
| Bootloader | 0x0–0x80000 | read-only; untouched |
| Config | 0x80000–0xC0000 | stock Config preserved |
| Bdata | 0xC0000–0x100000 | read-only; preserved |
| factory | 0x100000–0x140000 | read-only; nvmem cells `eeprom@0`, `eeprom@8000`, `macaddr@e000`, `macaddr@e006` |
| crash | 0x140000–0x180000 | kept |
| crash_syslog | 0x180000–0x1C0000 | kept |
| reserved0 | 0x1C0000–0x200000 | read-only; stock cfg_bak slot preserved under a neutral name |
| kernel_stock | 0x200000–0x600000 | stock kernel0 preserved in place |
| kernel | 0x600000–0xA00000 | OpenWrt kernel (the former stock kernel1 slot) |
| ubi | 0xA00000–0x7F80000 | OpenWrt UBI; repurposes stock rootfs0 + rootfs1 + overlay + obr |

Consistency check (confirmed upstream): the `ubi` span is 0x7580000 =
120,320 KiB, exactly matching `IMAGE_SIZE := 120320k` in `mt7621.mk`. The
shared fragment `xiaomi_nand_separate` (Device/nand + uimage-lzma-loader)
emits `kernel1.bin` (`append-kernel`) and `rootfs0.bin` (`append-ubi |
check-size`) alongside the sysupgrade image; `kernel1.bin` targets the `kernel`
partition and `rootfs0.bin` the `ubi` partition. The same fragment also
defines `xiaomi_mi-router-ac2100` as a **separate** device (`DEVICE_MODEL :=
Mi Router AC2100`) — different DTS, different images, never valid here (see
the model warning above).

## Stock boot-state snapshot

Values at dump time (confirmed from dump; semantics per the flag table above):
active system = kernel0 + rootfs0 (`flag_boot_rootfs=0`), `flag_boot_type=2`,
`flag_ota_reboot=0`, `flag_last_success=0`, `flag_boot_success=1`,
`flag_try_sys1_failed=0`, `flag_try_sys2_failed=0`, `boot_wait=on`,
`uart_en=1`.

## Sensitive-data policy

The dumps contain real secrets: NVRAM values (including a system password
hash), Wi-Fi credentials, MAC addresses, the board serial number, and
unit-unique radio calibration data. Policy:

- Dump directories and archives are git-ignored;
  [../scripts/verify-repo.sh](../scripts/verify-repo.sh) hard-fails if dump
  data, private keys, Tailscale keys, NVRAM password values, UCI passwords, or
  real-looking MAC addresses ever become committable.
- Documentation uses `XX:XX:XX:XX:XX:XX` and `<your-...>` placeholders only.
- inspect-stock.ps1 is redaction-by-design: it classifies sensitive partitions
  structurally and never prints their contents.
