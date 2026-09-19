# Build

Purpose: how firmware images are produced — the CI-authoritative pipeline, the
optional local Linux build, and the reproducibility guarantees.

Status: pipeline implemented and wired in CI; the project is in the no-flash
stage, so no build output has been validated on hardware yet.

## Prerequisites

- **CI (authoritative)**: nothing local; everything runs on GitHub Actions
  `ubuntu-24.04`.
- **Local Linux (optional)**: the official OpenWrt build dependency set for
  Ubuntu 24.04 (confirmed upstream, per the OpenWrt build-system
  documentation; identical to what CI installs):

  ```
  build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
  gettext git libncurses5-dev libssl-dev python3-setuptools rsync swig \
  unzip zlib1g-dev file wget
  ```

- **Windows**: unsupported as a build host by design. This repository is
  authored on Windows, but firmware builds run in CI or on a local Linux
  machine. WSL2 might work but is untested and unsupported; CI is the
  reference environment.

## CI pipeline (authoritative)

[../.github/workflows/build.yml](../.github/workflows/build.yml) runs on pushes
to `main`, on pull requests, on manual dispatch, and as a reusable workflow
from release.yml. Two jobs:

1. **hygiene** (5-minute cap) —
   [../scripts/verify-repo.sh](../scripts/verify-repo.sh): proves no dump
   data/binaries are committable, proves the `.gitignore` rules, scans for
   secrets (private keys, Tailscale `tskey-` tokens, NVRAM password values,
   UCI passwords, real-looking MAC addresses), guards the device identity of
   the build inputs, and checks that required files exist.
2. **build** (needs: hygiene, 360-minute cap):
   - installs the official apt dependency set;
   - restores the two safe caches (below);
   - `bash scripts/prepare.sh` — shallow-clone OpenWrt v25.12.2, **verify HEAD
     equals the pinned commit** (hard-fail otherwise), update + install feeds
     (pinned to exact commits by the tag's `feeds.conf.default`), write
     `build-metadata.txt`, seed `.config` from the selected flavor, apply the
     `files/` overlay, apply any `patches/` (none currently);
   - `bash scripts/build.sh` — `make defconfig`, save `config.buildinfo`
     (diffconfig), `make download`, `make -j$(nproc)`, then
     [../scripts/verify-images.sh](../scripts/verify-images.sh);
   - uploads `*xiaomi_redmi-router-ac2100*` images plus `SHA256SUMS`,
     `build-metadata.txt` and `config.buildinfo` (14-day retention,
     `if-no-files-found: error`).

### Caching policy

Only two paths are cached, both safe by construction:

| Cache | Key shape | Why it is safe |
| --- | --- | --- |
| `work/openwrt/dl` (upstream source tarballs) | `openwrt-dl-25.12.2-<hash of config seeds>` | tarballs are content-fetched and hash-verified by the OpenWrt build system itself |
| `work/openwrt/.ccache` | `openwrt-ccache-25.12.2-<run_id>` with prefix restore-keys | ccache is content-addressed over preprocessed source; a hit is byte-identical to a fresh compile |

Build state (`build_dir/`, `staging_dir/`) is **never cached**: stale object
trees silently survive config and patch changes, which would make artifacts a
function of cache history instead of the declared inputs — the opposite of
reproducibility.

### Artifact validation

[../scripts/verify-images.sh](../scripts/verify-images.sh) hard-fails when:

- any `xiaomi_mi-router-ac2100` artifact exists (wrong device — never valid
  here);
- a required Redmi artifact (`squashfs-kernel1`, `squashfs-rootfs0`,
  `squashfs-sysupgrade`) is missing, empty, duplicated, or below a
  conservative size floor (floors derive from the official 25.12.2 sizes:
  kernel1 3,312,916 B, rootfs0 6,029,312 B, sysupgrade 8,233,543 B —
  confirmed upstream);
- the build `.config` (when reachable) does not select the Redmi device
  profile.

On success it writes `SHA256SUMS` over all device `.bin` files.

### Release flow

[../.github/workflows/release.yml](../.github/workflows/release.yml) is
**manual-only** (`workflow_dispatch`) — pushing a `v*` tag triggers nothing.
It reuses build.yml via `workflow_call` to build and validate the release
artifacts. Only when explicitly dispatched with `publish_release=true` and a
`tag` input does it create a GitHub **prerelease** with generated notes:
artifact meanings, checksum verification (`sha256sum -c SHA256SUMS`), build
metadata, and an explicit statement that flashing instructions are
intentionally not published yet. Nothing is ever published automatically; a
human reviews artifacts before any prerelease is marked stable.

## Optional local Linux build

Same entry points as CI:

```
scripts/prepare.sh          # FLAVOR=full|base (default: full), WORK_DIR=<path> (default: work/openwrt)
scripts/build.sh            # BUILD_JOBS=<n> (default: nproc), MAKE_V=s for verbose logs
scripts/verify-images.sh    # standalone re-validation of work/openwrt/bin/targets/ramips/mt7621
```

prepare.sh is idempotent and refuses to touch an existing checkout whose HEAD
does not equal the pinned commit.

## Flavors

| Flavor | Seeds | Adds on top of the device defaults |
| --- | --- | --- |
| `base` | [../config/base.config](../config/base.config) | device profile, LuCI, ppp + ppp-mod-pppoe, odhcp6c + odhcpd-ipv6only, ccache |
| `full` (default) | base + [../config/performance.config](../config/performance.config) | iperf3, tcpdump-mini, ethtool, conntrack, htop; tailscale; smartdns + luci-app-smartdns |

Deliberately excluded in every flavor: SQM/cake, irqbalance, samba/dlna/usb,
wpad-full — rationale in [performance.md](performance.md).

## Patches convention

prepare.sh wires three patch locations (all currently empty — **no patches
exist**):

| Repo path | Applied to |
| --- | --- |
| `patches/openwrt/*.patch` | `git apply` at the buildroot root |
| `patches/kernel/*.patch` | copied into `target/linux/ramips/patches-6.12/` |
| `patches/packages/<feed>/<pkg>/*.patch` | copied into `feeds/<feed>/<pkg>/patches/` |

## Reproducibility notes

| Input | Pin | Evidence |
| --- | --- | --- |
| OpenWrt source | commit `d266501ad6188cce279a487b1ce61f4f327cd496` (signed tag `v25.12.2`, tag object `02fe9b4f4872fdb1703f04379fd063c7e27c7aa4`, tagger Hauke Mehrtens, 2026-03-26) | confirmed upstream; prepare.sh hard-fails on any other HEAD |
| Feed `packages` | `268d92d3d46147efe1e81892e3a618f8bbd4806b` | confirmed upstream (tag's `feeds.conf.default`) |
| Feed `luci` | `067535eaf51a59582b775a8b588a9b05810f8030` | confirmed upstream |
| Feed `routing` | `5b23ea12d417e5dba99788c5b34abdae81cccf33` | confirmed upstream |
| Feed `telephony` | `2618106d5846a4a542fdf5809f0d3ed228ce439b` | confirmed upstream |
| Feed `video` | `094bf58da6682f895255a35a84349a79dab4bf95` | confirmed upstream |
| Kernel | 6.12.74 (`KERNEL_PATCHVER=6.12`, `LINUX_VERSION-6.12=.74`; vermagic `e907f034ad3de2d6a38bc36369b413fa` in official profiles.json) | confirmed upstream |
| Package versions (full flavor) | tailscale 1.94.1, smartdns 46.1 at the pinned feed commits | confirmed upstream |
| Recorded per build | `build-metadata.txt` (versions, feed HEADs, UTC date), `config.buildinfo` (diffconfig), `SHA256SUMS` | generated artifacts |

Given the same repository revision, image content is intended to be a pure
function of these pinned inputs; bit-for-bit identity with the official
upstream build is not claimed (different config, timestamps and build host).

Official upstream reference for this device
(`downloads.openwrt.org/releases/25.12.2/targets/ramips/mt7621/`, confirmed
upstream): exactly four images — `initramfs-kernel.bin`,
`squashfs-kernel1.bin`, `squashfs-rootfs0.bin`, `squashfs-sysupgrade.bin` —
plus profiles.json reporting supported_devices `xiaomi,redmi-router-ac2100`,
version_code `r32802-f505120278`, arch `mipsel_24kc`. **No factory.bin exists
for this device.**
