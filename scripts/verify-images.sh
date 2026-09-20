#!/usr/bin/env bash
# verify-images.sh - validate generated Redmi AC2100 firmware artifacts.
#
# Usage:  scripts/verify-images.sh [IMAGE_DIR]
#         default IMAGE_DIR: work/openwrt/bin/targets/ramips/mt7621
#
# Hard-fails (exit 1) when:
#   - any Xiaomi Mi Router AC2100 artifact exists (wrong device - never valid)
#   - a required Redmi AC2100 artifact is missing/empty/outside size bounds
#   - the build .config (when reachable) does not select the Redmi device
#   - a magic/header check fails (uImage / UBI / sysupgrade tar+metadata)
#   - profiles.json disagrees with the artifacts (device, arch, sha256)
#   - a partition upper bound is exceeded (see limits below)
# On success writes SHA256SUMS and appends artifact facts to build-metadata.txt.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="${1:-${REPO_ROOT}/work/openwrt/bin/targets/ramips/mt7621}"
DEV="xiaomi_redmi-router-ac2100"
DEV_DTS="xiaomi,redmi-router-ac2100"
BAD="xiaomi_mi-router-ac2100"

# ---- Size limits (bytes) ---------------------------------------------------------
# Floors: conservative fractions of the official 25.12.5 images
#   (kernel1 3.3 MB, rootfs0 6.0 MB, sysupgrade 8.2 MB).
# Ceilings are device-authoritative, from OpenWrt v25.12.5
#   target/linux/ramips/dts/mt7621_xiaomi_nand_128m.dtsi and mt7621.mk:
#   - kernel1.bin -> OpenWrt "kernel" partition 0x600000-0xA00000 = 4 MiB
#   - rootfs0.bin -> "ubi" span 0xA00000-0x7F80000 = 120320 KiB (= IMAGE_SIZE,
#     already enforced upstream by check-size; belt-and-braces here)
#   - sysupgrade is a tar(kernel + rootfs) + metadata: composition sanity bound
#     = kernel partition + ubi span + 4 MiB slack. It is not flashed as one blob.
#   - initramfs-kernel is RAM-loaded (no flash partition): sanity window only.
K_MIN=2097152;      K_MAX=4194304          # 4 MiB kernel partition
R_MIN=4194304;      R_MAX=123207680        # 120320 KiB ubi span
S_MIN=5242880;      S_MAX=131596288        # kernel part + ubi span + 4 MiB slack
I_MIN=3145728;      I_MAX=67108864         # initramfs sanity window (RAM)

fail=0
err() { echo "VERIFY-FAIL: $*" >&2; fail=1; }
log() { printf '==> %s\n' "$*"; }

# initramfs is produced by the source Buildroot pipeline (it owns kernel-level
# artifacts); the ImageBuilder pipeline sets REQUIRE_INITRAMFS=0 because the
# official IB is not guaranteed to emit it and is not its research vehicle.
REQUIRE_INITRAMFS="${REQUIRE_INITRAMFS:-1}"

[ -d "${IMAGE_DIR}" ] || { echo "ERROR: image dir not found: ${IMAGE_DIR}" >&2; exit 1; }
IMAGE_DIR="$(cd "${IMAGE_DIR}" && pwd)"   # resolve before any later cd
cd "${IMAGE_DIR}"

# glob helper: expands to zero or more existing files, never to a literal pattern
glob_list() {  # glob_list <pattern>...
    local pat
    for pat in "$@"; do
        compgen -G "${pat}" || true
    done
}

PY=
if command -v python3 >/dev/null 2>&1; then PY=python3; elif command -v python >/dev/null 2>&1; then PY=python; fi

# ---- 0. Build identity (only when a Buildroot .config is reachable) ---------------
# ImageBuilder output dirs have no such .config; manifest/profile checks in
# imagebuild.sh carry the identity audit there. This section is for the
# source-build pipeline only.
OPENWRT_ROOT="$(cd "${IMAGE_DIR}/../../../.." 2>/dev/null && pwd || true)"
if [ -n "${OPENWRT_ROOT}" ] && [ -f "${OPENWRT_ROOT}/.config" ]; then
    if grep -qE '^(CONFIG_TARGET_MULTI_PROFILE|CONFIG_TARGET_ALL_PROFILES)=y' "${OPENWRT_ROOT}/.config"; then
        # ImageBuilder/official-style config: every device profile is enabled,
        # including the Mi Router AC2100. Per-device symbol checks are
        # meaningless here; identity is proven by artifact names, sysupgrade
        # metadata, and profiles.json below.
        log "NOTE: multi-profile (ImageBuilder) .config - per-device symbol check skipped by design"
    elif ! grep -q "^CONFIG_TARGET_ramips_mt7621_DEVICE_${DEV}=y" "${OPENWRT_ROOT}/.config"; then
        err ".config does not select ${DEV}"
    elif grep -q "DEVICE_${BAD}=y" "${OPENWRT_ROOT}/.config"; then
        err ".config selects ${BAD}"
    elif ! grep -q '^CONFIG_TARGET_ramips_mt7621=y' "${OPENWRT_ROOT}/.config"; then
        err ".config is not ramips/mt7621"
    else
        log "Build identity: .config selects ramips/mt7621 ${DEV}"
    fi
else
    log "NOTE: build .config not reachable from image dir; skipping build-identity check"
fi

# ---- 1. Forbidden device -----------------------------------------------------------
# Any "mi-router" artifact that is not literally "redmi-router" is forbidden;
# matching the bare substring keeps this robust against naming variants.
mapfile -t maybe_bad < <(glob_list "*mi-router*")
bad_files=()
for f in ${maybe_bad[@]+"${maybe_bad[@]}"}; do
    case "$f" in
        *redmi-router*) ;;                        # ours
        *) bad_files+=("$f") ;;
    esac
done
if [ ${#bad_files[@]} -gt 0 ]; then
    err "forbidden Mi Router AC2100 artifact(s) present: ${bad_files[*]}"
fi

# ---- 2. Required artifacts + size windows -------------------------------------------
declare -A FOUND
check_one() {
    local kind="$1" min="$2" max="$3" f size
    # real names: <DEV>-squashfs-<kind>.bin, except initramfs: <DEV>-initramfs-kernel.bin
    local matches=()
    mapfile -t matches < <(glob_list "*${DEV}-squashfs-${kind}.bin" "*${DEV}-${kind}.bin")
    if [ ${#matches[@]} -eq 0 ]; then err "missing *${DEV}-*-${kind}.bin"; return; fi
    if [ ${#matches[@]} -gt 1 ]; then err "multiple ${kind} images: ${matches[*]}"; return; fi
    f="${matches[0]}"
    [ -s "$f" ] || { err "$f is empty"; return; }
    size=$(stat -c %s "$f")
    if [ "${size}" -lt "${min}" ]; then err "$f too small: ${size} < ${min}"; return; fi
    if [ "${size}" -gt "${max}" ]; then err "$f EXCEEDS partition limit: ${size} > ${max}"; return; fi
    FOUND[$kind]="$f"
    printf '  OK  %-72s %10d bytes (limit %d)\n' "$f" "${size}" "${max}"
}

log "Required artifacts (size window = floor .. partition-fit ceiling):"
check_one kernel1    ${K_MIN} ${K_MAX}
check_one rootfs0    ${R_MIN} ${R_MAX}
check_one sysupgrade ${S_MIN} ${S_MAX}

# initramfs is required only where this run's pipeline owns it (source build).
if [ "${REQUIRE_INITRAMFS}" = "1" ]; then
    check_one initramfs-kernel ${I_MIN} ${I_MAX}
else
    initramfs_matches=()
    mapfile -t initramfs_matches < <(glob_list "*${DEV}-initramfs-kernel.bin")
    if [ ${#initramfs_matches[@]} -gt 0 ]; then
        printf '  OK  %-72s (present; not required by this pipeline)\n' "${initramfs_matches[0]}"
        FOUND[initramfs-kernel]="${initramfs_matches[0]}"
    else
        log "note: no initramfs-kernel.bin (not required by this pipeline)"
    fi
fi

# ---- 3. Magic / structure -----------------------------------------------------------
magic_u32() {  # magic_u32 <file> - prints first 4 bytes as hex
    od -A n -t x1 -N 4 "$1" | tr -d ' \n'
}
if [ -n "${FOUND[kernel1]:-}" ]; then
    [ "$(magic_u32 "${FOUND[kernel1]}")" = "27051956" ] \
        || err "${FOUND[kernel1]}: not a uImage (magic $(magic_u32 "${FOUND[kernel1]}"))"
fi
if [ -n "${FOUND[initramfs-kernel]:-}" ]; then
    [ "$(magic_u32 "${FOUND[initramfs-kernel]}")" = "27051956" ] \
        || err "${FOUND[initramfs-kernel]}: not a uImage"
fi
if [ -n "${FOUND[rootfs0]:-}" ]; then
    [ "$(magic_u32 "${FOUND[rootfs0]}")" = "55424923" ] \
        || err "${FOUND[rootfs0]}: does not start with UBI EC magic ('UBI#')"
fi
if [ -n "${FOUND[sysupgrade]:-}" ]; then
    SY="${FOUND[sysupgrade]}"
    m="$(magic_u32 "${SY}")"
    if [ "${m:0:4}" = "1f8b" ]; then
        TAR_CMD=(tar -tzf)
    elif [ "$(dd if="${SY}" bs=1 skip=257 count=5 2>/dev/null)" = "ustar" ]; then
        TAR_CMD=(tar -tf)
    else
        err "${SY}: neither gzip nor uncompressed tar"; TAR_CMD=()
    fi
    if [ ${#TAR_CMD[@]} -gt 0 ]; then
        members="$("${TAR_CMD[@]}" "${SY}" 2>/dev/null || true)"
        grep -q 'CONTROL' <<<"${members}" || err "${SY}: sysupgrade tar lacks CONTROL member"
        grep -qE '(^|/)kernel$' <<<"${members}" || err "${SY}: sysupgrade tar lacks kernel member"
        grep -qE '(^|/)root$' <<<"${members}" || err "${SY}: sysupgrade tar lacks root member"
        # appended image metadata (append-metadata) must name our device
        if ! tail -c 8192 "${SY}" | grep -qa "${DEV_DTS}"; then
            err "${SY}: appended metadata does not name supported device ${DEV_DTS}"
        fi
        log "sysupgrade structure: tar members + device metadata OK"
    fi
fi

# ---- 4. profiles.json cross-check (upstream-generated metadata) ----------------------
if [ -f profiles.json ] && [ -n "${PY}" ]; then
    log "Cross-checking profiles.json"
    "${PY}" - "${DEV}" <<'PYEOF' || fail=1
import json, sys, hashlib, os
dev = sys.argv[1]
data = json.load(open("profiles.json"))
if data.get("target") != "ramips/mt7621":
    print(f"VERIFY-FAIL: profiles.json target={data.get('target')!r}", file=sys.stderr); sys.exit(1)
prof = data.get("profiles", {}).get(dev)
if not prof:
    print(f"VERIFY-FAIL: profiles.json lacks profile {dev}", file=sys.stderr); sys.exit(1)
titles = " ".join(t.get("model","")+t.get("vendor","") for t in prof.get("titles", []))
if "Redmi Router AC2100" not in titles:
    print(f"VERIFY-FAIL: unexpected titles {prof.get('titles')!r}", file=sys.stderr); sys.exit(1)
if data.get("arch_packages") not in (None, "mipsel_24kc"):
    print(f"VERIFY-FAIL: arch {data.get('arch_packages')!r}", file=sys.stderr); sys.exit(1)
bad = [i for i in os.listdir(".")
       if "xiaomi_mi-router-ac2100" in i or ("mi-router" in i and "redmi-router" not in i)]
if bad:
    print(f"VERIFY-FAIL: mi-router artifacts present {bad}", file=sys.stderr); sys.exit(1)
checked = 0
for img in prof.get("images", []):
    name = img.get("name", "")
    if not name or not os.path.isfile(name):
        continue
    want = img.get("sha256")
    if not want:
        continue
    got = hashlib.sha256(open(name, "rb").read()).hexdigest()
    if got != want:
        print(f"VERIFY-FAIL: sha256 mismatch on {name}", file=sys.stderr); sys.exit(1)
    checked += 1
print(f"profiles.json: device/arch OK, {checked} image sha256 cross-checks passed")
PYEOF
else
    log "NOTE: profiles.json or python3 unavailable; skipped metadata cross-check"
fi

# ---- 5. Build metadata (copied next to artifacts when available) ----------------------
if [ -n "${OPENWRT_ROOT}" ]; then
    for m in "${OPENWRT_ROOT}/../build-metadata.txt" "${OPENWRT_ROOT}/../config.buildinfo"; do
        [ -f "$m" ] && cp -f "$m" "${IMAGE_DIR}/" || true
    done
fi

# ---- 6. Checksums + artifact facts ------------------------------------------------------
sums=()
mapfile -t sums < <(glob_list "*${DEV}*.bin")
if [ ${#sums[@]} -gt 0 ] && [ ${fail} -eq 0 ]; then
    sha256sum "${sums[@]}" | sort -k2 > SHA256SUMS
    log "SHA256SUMS written (${#sums[@]} files)"
    {
        echo ""
        echo "# artifacts (recorded by verify-images.sh)"
        for f in "${sums[@]}"; do
            printf 'artifact name=%s size=%s sha256=%s\n' "$f" "$(stat -c %s "$f")" \
                "$(sha256sum "$f" | cut -d' ' -f1)"
        done
    } >> "${IMAGE_DIR}/build-metadata.txt" 2>/dev/null || true
fi

if [ ${fail} -ne 0 ]; then
    echo "verify-images: FAILED" >&2
    exit 1
fi
log "verify-images: all checks passed"
