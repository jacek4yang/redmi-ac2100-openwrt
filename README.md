# redmi-ac2100-openwrt

Custom OpenWrt firmware for the Xiaomi Redmi Router AC2100, built as a thin,
auditable customization layer on top of a pinned upstream OpenWrt release.

**Stability stage: BUILD-VERIFIED** (of BUILD-VERIFIED → RAM-BOOT-VERIFIED →
HARDWARE-VALIDATED → PERFORMANCE-VALIDATED → SOAK-VALIDATED →
RELEASE-CANDIDATE). Images build reproducibly in CI and pass structural
verification; no device has ever been flashed or even RAM-booted from this
repository, and no performance or stability claim has been measured yet. The
prepared hardware-validation procedure lives in
[docs/hardware-validation.md](docs/hardware-validation.md); the benchmark
methodology (all results `NOT TESTED`) in
[docs/benchmarks.md](docs/benchmarks.md).

> **Model warning.** This firmware targets the **Xiaomi Redmi Router AC2100**
> (the six-antenna Redmi model, board name RM2100). It is **not** the Xiaomi
> Mi Router AC2100 — that is a different device with a different device-tree
> and image layout. Mixing the two bricks the flash layout. The build pipeline
> hard-fails if any Mi Router AC2100 artifact is ever produced
> ([scripts/verify-images.sh](scripts/verify-images.sh)).

## Baseline

| Item | Value | Evidence |
| --- | --- | --- |
| OpenWrt release | v25.12.5 | confirmed upstream (newest 25.12.x as of 2026-09-20) |
| Pinned commit | `f0a60eee2fe051741c643ea6118718aae1ef17fb` | confirmed upstream (tag `v25.12.5`) |
| Target / device | `ramips/mt7621`, `xiaomi_redmi-router-ac2100` | confirmed upstream |
| Kernel | 6.12.94 (ramips `KERNEL_PATCHVER=6.12`) | confirmed upstream |
| Feeds | exact commits from the tag's `feeds.conf.default` | confirmed upstream; table in [docs/build.md](docs/build.md) |
| Upgrade rationale | 25.12.2 → 25.12.5: critical odhcpd/dnsmasq CVEs, mt7621 reset-hang fix, kernel 6.12.94 | 249-commit compare; DTS/image recipe byte-identical |

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
| [config/base.config](config/base.config) | canonical full-Buildroot config seed (source-build pipeline) |
| [config/packages-base.list](config/packages-base.list) / [config/packages-full.list](config/packages-full.list) | ImageBuilder flavor package lists |
| [files/etc/uci-defaults/](files/etc/uci-defaults/) | first-boot runtime tuning |
| [scripts/](scripts/) | imagebuild / prepare / build / verify pipeline + read-only stock-dump inspector |
| [.github/workflows/](.github/workflows/) | hygiene + ImageBuilder + source-build pipelines, manual-only release flow |
| [docs/](docs/) | hardware, flash layout, build, performance, IPv6, Tailscale, recovery, benchmarks |
| `dump-*/` | stock NAND dumps — git-ignored, never committed (policy: [docs/stock-flash-layout.md](docs/stock-flash-layout.md)) |
| `work/` | build trees created by the scripts — git-ignored |

## How the build works

CI is authoritative. Three separated pipelines on GitHub Actions Ubuntu 24.04:

1. **hygiene** ([hygiene.yml](.github/workflows/hygiene.yml)) — every push/PR:
   shellcheck, bash syntax, and
   [scripts/verify-repo.sh](scripts/verify-repo.sh) (no dump data committable,
   ignore rules proven, secrets scan, device-identity guard).
2. **imagebuilder** ([imagebuilder.yml](.github/workflows/imagebuilder.yml)) —
   the user-facing firmware. Uses the **official OpenWrt 25.12.5
   ImageBuilder** (SHA256-verified against upstream `sha256sums`), so no
   toolchain/kernel/host-Go compilation ever runs here. Three milestone
   layers, each producing verified artifacts:
   `smoke` (profile + defaults + LuCI) → `base` (+ `files/` overlay) →
   `full` (+ observability/Tailscale/SmartDNS from official precompiled
   feeds). Runs when image-relevant inputs change.
3. **source-build** ([source-build.yml](.github/workflows/source-build.yml)) —
   the full pinned Buildroot for kernel/DTS/patch/initramfs work. One
   canonical config ([config/base.config](config/base.config)). Manual or
   source-level path changes only; `cancel-in-progress: false` so a later
   push never kills a multi-hour build. Stage-separated steps
   (prepare → defconfig → config audit → download → compile →
   image-generation check → custom image audit) make the failing layer
   obvious in the UI.

Both build pipelines end with [scripts/verify-images.sh](scripts/verify-images.sh)
(device identity, structure, partition-fit ceilings, `profiles.json`
cross-check, `SHA256SUMS`).

[.github/workflows/release.yml](.github/workflows/release.yml) runs **only when
manually dispatched** (`workflow_dispatch`). By default it just rebuilds and
validates artifacts; it creates a GitHub **prerelease** only when explicitly
dispatched with `publish_release=true` and a tag. Pushing a `v*` tag triggers
nothing; nothing is published automatically.

Local Linux builds are optional (`scripts/prepare.sh` + `scripts/build.sh` for
source, `scripts/imagebuild.sh <smoke|base|full>` for image flavors). Windows
is a development-only platform here. Full detail: [docs/build.md](docs/build.md).

## Artifacts

| Artifact | Meaning |
| --- | --- |
| `*-squashfs-kernel1.bin` | OpenWrt kernel image for the `kernel` partition; half of the initial-flash pair (with rootfs0) |
| `*-squashfs-rootfs0.bin` | OpenWrt UBI rootfs image; half of the initial-flash pair (with kernel1) |
| `*-squashfs-sysupgrade.bin` | combined image for OpenWrt-to-OpenWrt upgrades |
| `*-initramfs-kernel.bin` | RAM-only image for netboot/recovery scenarios (produced by the source-build pipeline, which owns kernel-level artifacts; `CONFIG_TARGET_ROOTFS_INITRAMFS=y` in base.config) |
| `sha256sums` (ImageBuilder) / `SHA256SUMS` (source-build) | checksums over the shipped files |
| `build-metadata.txt`, `profiles.json`, `packages.manifest` | pinned-revision provenance, device identity, resolved package set |
| `config.buildinfo` | sanitized resolved config (diffconfig); source-build artifacts only |

Upstream ships **no factory.bin** for this device (confirmed upstream); the
device image fragment emits the `kernel1.bin` / `rootfs0.bin` pair instead.
Flashing instructions are deliberately not published at this stage.

## Flavors

User-facing flavors are built by the ImageBuilder pipeline (official
precompiled packages, no recompilation):

| Flavor | Package lists | Contents |
| --- | --- | --- |
| `base` | [config/packages-base.list](config/packages-base.list) | official profile defaults + LuCI (PPPoE and the IPv6 stack are already in the OpenWrt default set) |
| `full` | base + [config/packages-full.list](config/packages-full.list) | + iperf3, tcpdump-mini, ethtool, conntrack, htop, tailscale, smartdns + luci-app-smartdns |

Both flavors apply the `files/` overlay (first-boot runtime tuning). Rationale
per package: [docs/performance.md](docs/performance.md) and the list files
themselves. The source-build pipeline compiles exactly one canonical config —
flavor matrices belong to the ImageBuilder, not to toolchain rebuilds.

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
