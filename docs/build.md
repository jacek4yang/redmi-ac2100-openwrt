# Build

Purpose: how this repository turns pinned upstream OpenWrt into verified Redmi
Router AC2100 firmware, and how to reproduce it.

Status: redesigned pipeline (hygiene / ImageBuilder / source-build) —
milestone results are recorded in *CI failure history* below as they land.

## Pipelines at a glance

| Workflow | Trigger | Purpose | Typical duration |
| --- | --- | --- | --- |
| [hygiene.yml](../.github/workflows/hygiene.yml) | every push + PR | shellcheck, bash syntax, `verify-repo.sh` (secrets/ignores/device identity) | < 1 min |
| [imagebuilder.yml](../.github/workflows/imagebuilder.yml) | image-relevant changes, PRs, manual | **user-facing firmware** via the official ImageBuilder (no compilation) | minutes |
| [source-build.yml](../.github/workflows/source-build.yml) | source-level changes, manual | full Buildroot for kernel/DTS/patch/initramfs work | hours |
| [release.yml](../.github/workflows/release.yml) | **manual only** | optionally publish a prerelease (default: build+validate only) | minutes |

Path filters keep expensive runs off irrelevant commits: docs-only commits run
just hygiene; ImageBuilder runs for `config/packages-*.list`, `files/**`,
`scripts/imagebuild.sh`, `scripts/verify-images.sh`; source-build runs for
`config/base.config`, `patches/**`, the source-pipeline scripts, or manual
dispatch. The source build uses `cancel-in-progress: false` so a later push
can never kill a multi-hour build.

## Design rule: ImageBuilder for packages, Buildroot for source

Recompiling GCC/binutils/the kernel/host Go just to change the package set is
wasteful and was the direct cause of this repository's first CI failure (see
the history section). So:

- **Package/rootfs variants are made with the official OpenWrt ImageBuilder**
  (precompiled packages from the official 25.12.2 feeds; flavors below).
- **Full Buildroot is kept for source-level work only**: kernel, DTS,
  `patches/`, driver/PPE development, initramfs production. It builds exactly
  one canonical config ([../config/base.config](../config/base.config) =
  device profile + LuCI + initramfs + ccache). No flavor matrix is compiled
  from source.

## ImageBuilder pipeline (user-facing firmware)

- Archive: `openwrt-imagebuilder-25.12.2-ramips-mt7621.Linux-x86_64.tar.zst`,
  SHA256-verified against the upstream `sha256sums` before extraction
  (`c3bc6a9713054e278a8f010ee3b64b280362c3bf753aa291c63fc9cdd2d4d3ce`),
  cached by that hash. 25.12 uses the **apk** package manager; the
  ImageBuilder handles it internally.
- The exact profile is proven at runtime (`make info` must contain
  `xiaomi_redmi-router-ac2100:`).
- Driver: [../scripts/imagebuild.sh](../scripts/imagebuild.sh)
  `<smoke|base|full>`.

Milestones (sequential steps in one job; the failed step names the layer):

| Milestone | Flavor | Contents |
| --- | --- | --- |
| A | `smoke` | profile defaults (incl. ppp/ppp-mod-pppoe, odhcp6c, odhcpd-ipv6only, firewall4, dropbear, wpad-basic-mbedtls, kmod-mt7603, kmod-mt7615-firmware) + `luci`; no `files/` overlay |
| B | `base` | smoke + [../config/packages-base.list](../config/packages-base.list) + `files/` overlay (first-boot tuning) |
| C | `full` | base + [../config/packages-full.list](../config/packages-full.list) (iperf3, tcpdump-mini, ethtool, conntrack, htop, tailscale, smartdns, luci-app-smartdns) |

After each build the script audits the generated `.manifest` (required
packages present; flavor isolation — e.g. tailscale must not leak into
smoke/base), then [verify-images.sh](../scripts/verify-images.sh) validates
the artifacts (see below). `initramfs` is **not** required from this pipeline:
RAM-bootable images are the source pipeline's job.

## Source-build pipeline (full Buildroot)

For source-level development. Stages are separate named workflow steps so the
GitHub UI immediately shows which layer failed:

```
[ENV] -> [DISK] -> deps -> [CLONE+FEEDS] -> [DEFCONFIG] -> [CONFIG VERIFY]
     -> [DOWNLOAD] -> [COMPILE] -> [IMAGE GENERATION] -> [CUSTOM VERIFY]
     -> [CACHE] -> [MEASURE] -> upload
```

- **Pinned upstream**: tag `v25.12.2`, commit-verified to
  `d266501ad6188cce279a487b1ce61f4f327cd496` by
  [../scripts/prepare.sh](../scripts/prepare.sh); feeds pinned by the tag's
  own `feeds.conf.default` (exact commits, recorded into
  `build-metadata.txt`).
- **[DISK]**: the runner's free space is measured before/after removing only
  unused preinstalled toolchains (dotnet/Android/GHC/docker images/…); the job
  fails fast if < 30 GiB remain. Evidence: see failure history.
- **[CONFIG VERIFY]**: [verify-config.sh](../scripts/verify-config.sh) audits
  the resolved `.config` right after `defconfig` (device identity, PPPoE,
  firewall4, IPv6, LuCI, mt76 radios, initramfs, bloat tripwires) — minutes,
  not hours, lost on a config mistake.
- **[DOWNLOAD]**: `make download -j$(nproc)`; then any `dl/` file smaller than
  1024 bytes is treated as an incomplete download, deleted, and the download
  retried once (the established OpenWrt-Actions convention); remaining
  breakage fails the stage.
- **[COMPILE]**: `make -j$(nproc)`; on failure the build automatically re-runs
  `make -j1 V=s` so the exact compiler error is in the step log. No opaque
  retries.
- **[IMAGE GENERATION]** vs **[CUSTOM VERIFY]**: two separate steps — the
  first confirms upstream emitted the Redmi artifacts at all, the second runs
  our audit. A failure is unmistakably attributable to OpenWrt or to us.
- **[CACHE]**: ccache statistics are printed when present (`work/openwrt/.ccache`;
  `CONFIG_CCACHE=y` in base.config). Cache benefit is claimed only from
  observed hits, never assumed.
- **[MEASURE]**: `df`/`du` evidence for resource tuning.
- Failure diagnostics (build `logs/`, resolved config) upload as a separate
  artifact on failure only.

Local equivalent on a Linux machine: `scripts/prepare.sh` then
`scripts/build.sh`.

## Caching policy

| Cache | Key | Why safe |
| --- | --- | --- |
| ImageBuilder tarball | `ib-25.12.2-<upstream sha256>` | content-verified against upstream `sha256sums` on every use |
| `work/openwrt/dl` | `openwrt-dl-25.12.2` | tarballs are hash-verified by the OpenWrt build system itself |
| `work/openwrt/.ccache` | `openwrt-ccache-src-25.12.2-<run_id>` + prefix restore | content-addressed compiler cache |

`build_dir/` and `staging_dir/` are **never cached** — stale object trees
would make artifacts a function of cache history instead of declared inputs.

## Artifact validation

[../scripts/verify-images.sh](../scripts/verify-images.sh) hard-fails when:
any Mi Router AC2100 artifact exists; a required artifact is missing, empty,
duplicated, or outside its size window; magic/structure checks fail (kernel1
and initramfs are uImage, rootfs0 starts with the UBI EC magic, sysupgrade is
a tar with `CONTROL`/`kernel`/`root` members whose appended metadata names
`xiaomi,redmi-router-ac2100`); `profiles.json` (when present) disagrees on
target/arch/device or a recorded sha256. On success it writes `SHA256SUMS` and
appends artifact names/sizes/hashes to `build-metadata.txt`.

Size ceilings come from upstream device data, not guesses: `kernel1 <= 4 MiB`
(the OpenWrt `kernel` partition 0x600000–0xA00000 in
`mt7621_xiaomi_nand_128m.dtsi`), `rootfs0 <= 120320 KiB` (the `ubi` span =
`IMAGE_SIZE`, also enforced upstream by `check-size`), sysupgrade bounded by
the documented composition (kernel + rootfs tar + metadata — it is not written
to a single physical partition), initramfs within a RAM-image sanity window.
Floors are conservative fractions of the official 25.12.2 artifact sizes.

## Release flow

[../.github/workflows/release.yml](../.github/workflows/release.yml) is
**manual-only** (`workflow_dispatch`) — pushing a `v*` tag triggers nothing.
It reuses imagebuilder.yml via `workflow_call`. Only when explicitly
dispatched with `publish_release=true` and a `tag` input does it create a
GitHub **prerelease** from the full-flavor artifacts.

## Reproducibility notes

- Upstream is pinned by tag **and** commit; feeds by exact commits; the
  ImageBuilder by SHA256; GitHub Actions by immutable SHAs.
- `config.buildinfo` (resolved diffconfig, source pipeline) and
  `packages.manifest` (exact installed packages, ImageBuilder pipeline) are
  archived with the artifacts.
- Build timestamps are metadata only. Bit-for-bit reproducibility between two
  CI runs is an open question by policy: it will be answered by comparing
  `SHA256SUMS` of two clean runs and reported honestly, not claimed in
  advance.

## CI failure history

Factual record, newest last. "Layer" attributes the failure to the responsible
stage; none of these were OpenWrt compilation defects.

| Run | Date (UTC) | Layer | Root cause | Resolution |
| --- | --- | --- | --- | --- |
| [35438257237](https://github.com/jacek4yang/redmi-ac2100-openwrt/actions/runs/35438257237) | 2026-09-19 | INFRA (runner disk) | stock runner had ~14 GiB free; `golang1.26` host (tailscale's build-time dependency at the time) and `ppp` failed simultaneously ~2 h in — the disk-exhaustion signature | free-disk-space step + fail-fast disk gate in source-build.yml |
| [35444693304](https://github.com/jacek4yang/redmi-ac2100-openwrt/actions/runs/35444693304) | 2026-09-19 | OUR POST-BUILD VALIDATION | OpenWrt compiled through image generation; then `verify-images.sh` was invoked as an executable while committed without the exec bit (Windows checkout) → exit 126 | verifiers invoked via `bash ...`; exec bits set in git (defense in depth) |
| 35450408204 | 2026-09-19 | — (completed **success**, superseded) | matrix double full-source build (base+full) — the architecture the redesign replaced; allowed to finish on its own | replaced by imagebuilder.yml / source-build.yml |
| [35452484841](https://github.com/jacek4yang/redmi-ac2100-openwrt/actions/runs/35452484841) | 2026-09-19 | OUR POST-BUILD VALIDATION | ImageBuilder compiled and packaged everything; then `verify-images.sh` applied its per-device Buildroot `.config` identity checks to the ImageBuilder's multi-profile `.config` (which legitimately enables *all* ramips/mt7621 devices) → false positive | per-device symbol checks scoped to real per-device Buildroot configs; multi-profile configs log a documented skip (ee561a1) |
| 35452484886 | 2026-09-19 | CANCELLED (by design) | queued behind the running source-build (`cancel-in-progress: false`), then superseded by a newer push before a job ever started; the running build was never interrupted | no defect — concurrency policy working as intended |
| [35453035164](https://github.com/jacek4yang/redmi-ac2100-openwrt/actions/runs/35453035164) | 2026-09-19 | OUR CI (cache/clone ordering) | `dl/`+ccache cache *restore* recreated `work/openwrt/` non-empty before `[CLONE+FEEDS]`, so `git clone` failed with exit 128; the prior green run (35452208528) had saved the cache, turning a latent ordering bug into a hard failure | cache steps moved after `prepare.sh`; `prepare.sh` now hard-fails with a clear diagnostic if the work dir is unexpectedly non-empty |

Milestone evidence (see README for the milestone definitions):

| Milestone | Run | Result |
| --- | --- | --- |
| A–C (ImageBuilder smoke/base/full) | [35453035114](https://github.com/jacek4yang/redmi-ac2100-openwrt/actions/runs/35453035114) @ ee561a1 | **PASS** (2m53s). All `sha256sums` entries verified locally after download; `kernel1.bin` byte-identical to the official 25.12.2 image (sha256 `6703f033…dcd5`); rootfs/sysupgrade same sizes as official, different hashes (build-time metadata in rootfs assembly — bit-for-bit identity with upstream is not claimed). `full` resolved `tailscale 1.98.3-r1`, `smartdns 46.1-r1`, `luci-app-smartdns`, `iperf3`, `tcpdump-mini`, `ethtool`, `conntrack`, `htop` — all from official precompiled feeds (no host Go compilation). |
| D–E (source Buildroot, canonical config + initramfs) | [35452208528](https://github.com/jacek4yang/redmi-ac2100-openwrt/actions/runs/35452208528) @ cc94b69 | **PASS** (53m34s). Emitted `initramfs-kernel.bin` (8,042,958 B), `kernel1` (3,417,262 B), `rootfs0` (6,029,312 B), `sysupgrade` (8,264,263 B); `SHA256SUMS` verified locally after download; feed commits recorded in `build-metadata.txt`. |
| A–C re-validation | [35460747891](https://github.com/jacek4yang/redmi-ac2100-openwrt/actions/runs/35460747891) @ e157798 | **PASS**. **Reproducibility probe:** the full-flavor `kernel1`/`rootfs0`/`sysupgrade` are **bit-for-bit identical** to the ee561a1 run (two clean runners, ~2.5 h apart). ImageBuilder images are reproducible for identical inputs. |
| D–E re-validation | [35460747904](https://github.com/jacek4yang/redmi-ac2100-openwrt/actions/runs/35460747904) @ e157798 | **PASS** (57m23s). First run exercising the cache-restore-after-clone fix on a cache hit; `dl/` cache (567 MB) restored successfully. Disk: 87 GiB free before cleanup → 115 GiB after (gate ≥ 30 GiB) → 104 GiB post-build (`build_dir` 9.1 GiB, `staging_dir` 753 MiB). `kernel1` bit-for-bit identical to the cc94b69 run; `rootfs0`/`sysupgrade`/`initramfs` **differ** — the source Buildroot path is *not* bit-for-bit reproducible across runs (unlike the ImageBuilder path); root cause not yet isolated (candidate: file mtimes in rootfs assembly), tracked as an open question, not claimed. |

Measured CI facts worth knowing:

- ccache: three consecutive green source runs (35452208528, 35460747904,
  35464072806) compiled **without** ccache. Root cause chain, established from
  the pinned source rather than guessed: `CONFIG_CCACHE`'s kconfig prompt is
  gated on `DEVEL` (`config/Config-devel.in:136`), so a seed containing only
  `CONFIG_CCACHE=y` is silently forced back to n by `make defconfig`. The
  follow-up attempt of exporting `CCACHE_DIR` as workflow env (run 35464072806)
  could not work either: `rules.mk:354` unconditionally `export
  CCACHE_DIR:=$(TOPDIR)/.ccache`, overriding the environment. Fix: seed now
  sets `CONFIG_DEVEL=y` + `CONFIG_CCACHE=y`, and verify-config.sh hard-fails if
  any seed `=y` symbol does not survive defconfig. No compile-time speedup is
  claimed until cache hits are observed in the `[CACHE]` step.

## Official upstream reference artifacts

`downloads.openwrt.org/releases/25.12.2/targets/ramips/mt7621/` (confirmed
upstream) ships for this device exactly: `initramfs-kernel.bin`,
`squashfs-kernel1.bin`, `squashfs-rootfs0.bin`, `squashfs-sysupgrade.bin` —
plus `profiles.json` with `supported_devices: xiaomi,redmi-router-ac2100`,
version_code `r32802-f505120278`, arch `mipsel_24kc`. **No factory.bin exists
for this device.**
