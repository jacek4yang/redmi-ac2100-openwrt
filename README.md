# redmi-ac2100-openwrt

Custom OpenWrt firmware for the Xiaomi Redmi Router AC2100, built as a thin,
auditable customization layer on top of a pinned upstream OpenWrt release.

Status: no-flash validation stage. Images are unbuilt and untested on hardware;
no device has ever been flashed from this repository, and the benchmark plan is
pending real hardware (see [docs/benchmarks.md](docs/benchmarks.md) and
[docs/recovery.md](docs/recovery.md)).

> **Model warning.** This firmware targets the **Xiaomi Redmi Router AC2100**
> (the six-antenna Redmi model, board name RM2100). It is **not** the Xiaomi
> Mi Router AC2100 — that is a different device with a different device-tree
> and image layout. Mixing the two bricks the flash layout. The build pipeline
> hard-fails if any Mi Router AC2100 artifact is ever produced
> ([scripts/verify-images.sh](scripts/verify-images.sh)).

## Baseline

| Item | Value | Evidence |
| --- | --- | --- |
| OpenWrt release | v25.12.2 | confirmed upstream |
| Pinned commit | `d266501ad6188cce279a487b1ce61f4f327cd496` | confirmed upstream (signed tag object `02fe9b4f4872fdb1703f04379fd063c7e27c7aa4`, tagger Hauke Mehrtens, 2026-03-26) |
| Target / device | `ramips/mt7621`, `xiaomi_redmi-router-ac2100` | confirmed upstream |
| Kernel | 6.12.74 (ramips `KERNEL_PATCHVER=6.12`) | confirmed upstream |
| Feeds | exact commits from the tag's `feeds.conf.default` | confirmed upstream; table in [docs/build.md](docs/build.md) |

This repository contains only the customization layer. OpenWrt itself is
cloned and commit-verified by [scripts/prepare.sh](scripts/prepare.sh) into
the git-ignored `work/` directory; nothing upstream is vendored here.

## Hardware summary

Full detail and evidence per component: [docs/hardware.md](docs/hardware.md).

| Component | Part |
| --- | --- |
| SoC | MediaTek MT7621A, dual-core MIPS 1004Kc V2.15 (4 threads), 880 MHz |
| RAM | 128 MiB DDR3 |
| Flash | 128 MiB NAND (layout: [docs/stock-flash-layout.md](docs/stock-flash-layout.md)) |
| Switch | MT7530 gigabit switch (1x WAN + 3x LAN) |
| Wi-Fi 2.4 GHz | MediaTek MT7603EN (802.11n), `kmod-mt7603` |
| Wi-Fi 5 GHz | MediaTek MT7615N (802.11ac), `kmod-mt7615-firmware` |
| Antennas | 6 external |
| Serial | ttyS1, 115200 8n1 (enabled in stock env) |

## Repository layout

| Path | Contents |
| --- | --- |
| [config/base.config](config/base.config) | minimal device/core config seed (diffconfig format) |
| [config/performance.config](config/performance.config) | observability + optional-feature layer (flavor `full`) |
| [files/etc/uci-defaults/](files/etc/uci-defaults/) | first-boot runtime tuning |
| [scripts/](scripts/) | prepare / build / verify pipeline + read-only stock-dump inspector |
| [.github/workflows/](.github/workflows/) | CI-authoritative build, manual-only release flow |
| [docs/](docs/) | hardware, flash layout, build, performance, IPv6, Tailscale, recovery, benchmarks |
| `dump-*/` | stock NAND dumps — git-ignored, never committed (policy: [docs/stock-flash-layout.md](docs/stock-flash-layout.md)) |
| `work/` | OpenWrt buildroot created by prepare.sh — git-ignored |

## How the build works

CI is authoritative. Firmware builds on GitHub Actions Ubuntu 24.04 via
[.github/workflows/build.yml](.github/workflows/build.yml):

1. **Hygiene gate** — [scripts/verify-repo.sh](scripts/verify-repo.sh): no dump
   data/binaries committable, ignore rules proven, secrets scan, device-identity
   guard, required-files check.
2. **Prepare** — clone OpenWrt v25.12.2 shallow, verify the pinned commit,
   install pinned feeds, seed the flavor config, apply the `files/` overlay.
3. **Build** — defconfig, resolved-config audit
   ([scripts/verify-config.sh](scripts/verify-config.sh)), download, make, then
   [scripts/verify-images.sh](scripts/verify-images.sh) validates artifacts
   (identity, structure, partition-fit ceilings, `profiles.json` cross-check)
   and writes `SHA256SUMS`.
4. **Upload** — images + `SHA256SUMS` + `build-metadata.txt` +
   `config.buildinfo` + `profiles.json`.

Steps 2–4 run as a **matrix over both flavors** (`base` and `full`), so CI
proves the lean fallback and the full image independently.

[.github/workflows/release.yml](.github/workflows/release.yml) runs **only when
manually dispatched** (`workflow_dispatch`). By default it just rebuilds and
validates artifacts; it creates a GitHub **prerelease** only when explicitly
dispatched with `publish_release=true` and a tag. Pushing a `v*` tag triggers
nothing; nothing is published automatically.

Local Linux builds are optional and use the same entry points
(`scripts/prepare.sh`, `scripts/build.sh`). Windows is a development-only
platform here: authoring and dump analysis happen on Windows, but firmware
builds run on GitHub Actions Ubuntu (or an optional local Linux machine).
Full detail: [docs/build.md](docs/build.md).

## Artifacts

| Artifact | Meaning |
| --- | --- |
| `*-squashfs-kernel1.bin` | OpenWrt kernel image for the `kernel` partition; half of the initial-flash pair (with rootfs0) |
| `*-squashfs-rootfs0.bin` | OpenWrt UBI rootfs image; half of the initial-flash pair (with kernel1) |
| `*-squashfs-sysupgrade.bin` | combined image for OpenWrt-to-OpenWrt upgrades |
| `*-initramfs-kernel.bin` | RAM-only image for netboot/recovery scenarios (explicitly enabled via `CONFIG_TARGET_ROOTFS_INITRAMFS=y` in base.config; validated in CI) |
| `SHA256SUMS`, `build-metadata.txt`, `config.buildinfo` | checksums, pinned-revision metadata, sanitized config (diffconfig) |

Upstream ships **no factory.bin** for this device (confirmed upstream); the
device image fragment emits the `kernel1.bin` / `rootfs0.bin` pair instead.
Flashing instructions are deliberately not published at this stage.

## Flavors

| Flavor | Config seeds | Contents |
| --- | --- | --- |
| `base` | `config/base.config` | device profile + LuCI + PPPoE + IPv6 baseline |
| `full` (default) | base + `config/performance.config` | + iperf3, tcpdump-mini, ethtool, conntrack, htop, tailscale, smartdns + luci-app-smartdns |

Select with `FLAVOR=base|full` (default `full`). Rationale per package:
[docs/performance.md](docs/performance.md) and the config files themselves.

## Documentation

- [docs/hardware.md](docs/hardware.md) — exact model identity, components, evidence
- [docs/stock-flash-layout.md](docs/stock-flash-layout.md) — stock NAND / UBI / bootloader reference
- [docs/build.md](docs/build.md) — CI and local build pipeline, caching, reproducibility
- [docs/performance.md](docs/performance.md) — fast-path architecture and tuning rationale
- [docs/ipv6-design.md](docs/ipv6-design.md) — current IPv4-only reality, future split-WAN IPv6 design
- [docs/tailscale.md](docs/tailscale.md) — why Tailscale ships and how it is (not) configured
- [docs/recovery.md](docs/recovery.md) — boot chain, backups, recovery architecture (no procedures)
- [docs/benchmarks.md](docs/benchmarks.md) — measurement methodology for real hardware

## Reverse-engineering tooling

The 2026-09-19 stock firmware dump was analyzed with two read-only tools:

- [scripts/inspect-stock.ps1](scripts/inspect-stock.ps1) — structural inspection
  of the NAND dump: size verification against stock `/proc/mtd`, uImage / UBI /
  squashfs format detection, mtd0 slice hashing, redacted classification of
  sensitive partitions.
- reverse-mcp — an IDA 9.2 (idalib) MCP server used for static analysis of
  stock binaries (e.g. the `bin/ated` engineering daemon; see
  [docs/stock-flash-layout.md](docs/stock-flash-layout.md)).

Both are project tooling, not runtime dependencies of the firmware.

## License

MIT — see [LICENSE](LICENSE). The license covers this repository's
customization layer; OpenWrt itself remains under its own upstream licenses.
