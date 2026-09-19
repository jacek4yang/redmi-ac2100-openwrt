#!/usr/bin/env bash
# verify-images.sh - validate generated Redmi AC2100 firmware artifacts.
#
# Usage:  scripts/verify-images.sh [IMAGE_DIR]
#         default IMAGE_DIR: work/openwrt/bin/targets/ramips/mt7621
#
# Hard-fails (exit 1) when:
#   - any Xiaomi Mi Router AC2100 artifact exists (wrong device - never valid here)
#   - a required Redmi AC2100 artifact is missing/empty/suspiciously small
#   - the build .config (when present) does not select the Redmi device profile
# On success writes SHA256SUMS into IMAGE_DIR and prints an artifact table.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_DIR="${1:-${REPO_ROOT}/work/openwrt/bin/targets/ramips/mt7621}"
DEV="xiaomi_redmi-router-ac2100"
BAD="xiaomi_mi-router-ac2100"

fail=0
err() { echo "VERIFY-FAIL: $*" >&2; fail=1; }
log() { printf '==> %s\n' "$*"; }

[ -d "${IMAGE_DIR}" ] || { echo "ERROR: image dir not found: ${IMAGE_DIR}" >&2; exit 1; }
IMAGE_DIR="$(cd "${IMAGE_DIR}" && pwd)"   # resolve before any later cd
cd "${IMAGE_DIR}"
shopt -s nullglob

# ---- 0. Build identity (when the build tree is present) -----------------------
OPENWRT_ROOT="$(cd "${IMAGE_DIR}/../../../.." 2>/dev/null && pwd || true)"
if [ -n "${OPENWRT_ROOT}" ] && [ -f "${OPENWRT_ROOT}/.config" ]; then
    grep -q "^CONFIG_TARGET_ramips_mt7621_DEVICE_${DEV}=y" "${OPENWRT_ROOT}/.config" \
        || err ".config does not select ${DEV}"
    grep -q "DEVICE_${BAD}=y" "${OPENWRT_ROOT}/.config" \
        && err ".config selects ${BAD}"
    grep -q '^CONFIG_TARGET_ramips_mt7621=y' "${OPENWRT_ROOT}/.config" \
        || err ".config is not ramips/mt7621"
    log "Build identity: .config selects ramips/mt7621 ${DEV}"
else
    log "NOTE: build .config not reachable from image dir; skipping build-identity check"
fi

# ---- 1. Forbidden device -------------------------------------------------------
bad_files=( *"${BAD}"* )
if [ ${#bad_files[@]} -gt 0 ]; then
    err "forbidden Mi Router AC2100 artifact(s) present: ${bad_files[*]}"
fi

# ---- 2. Required artifacts + sanity sizes --------------------------------------
# Floors are conservative fractions of the official 25.12.2 images
# (kernel1 3.3 MB, rootfs0 6.0 MB, sysupgrade 8.2 MB).
check_one() {
    local kind="$1" min="$2" f
    local matches=( *${DEV}-squashfs-${kind}.bin )
    if [ ${#matches[@]} -eq 0 ]; then err "missing *${DEV}-squashfs-${kind}.bin"; return; fi
    if [ ${#matches[@]} -gt 1 ]; then err "multiple ${kind} images: ${matches[*]}"; return; fi
    f="${matches[0]}"
    [ -s "$f" ] || { err "$f is empty"; return; }
    local size
    size=$(stat -c %s "$f")
    [ "${size}" -ge "${min}" ] || { err "$f suspiciously small: ${size} < ${min} bytes"; return; }
    printf '  OK  %-72s %10d bytes\n' "$f" "${size}"
}

log "Required artifacts:"
check_one kernel1    2097152
check_one rootfs0    4194304
check_one sysupgrade 5242880

# ---- 3. Build metadata (copied next to artifacts when available) ---------------
if [ -n "${OPENWRT_ROOT}" ]; then
    for m in "${OPENWRT_ROOT}/../build-metadata.txt" "${OPENWRT_ROOT}/../config.buildinfo"; do
        [ -f "$m" ] && cp -f "$m" "${IMAGE_DIR}/" || true
    done
fi

# ---- 4. Checksums ----------------------------------------------------------------
sums=( *${DEV}*.bin )
if [ ${#sums[@]} -gt 0 ] && [ ${fail} -eq 0 ]; then
    sha256sum "${sums[@]}" | sort -k2 > SHA256SUMS
    log "SHA256SUMS written (${#sums[@]} files)"
fi

if [ ${fail} -ne 0 ]; then
    echo "verify-images: FAILED" >&2
    exit 1
fi
log "verify-images: all checks passed"
