#!/usr/bin/env bash
# build.sh - local one-shot driver for the canonical source build.
#
# CI (source-build.yml) runs the same stages as separately named steps; this
# script exists for local Linux builds and mirrors that stage order.
#
# Usage:  scripts/build.sh
# Env:    WORK_DIR=<path>   (default: work/openwrt)
#         BUILD_JOBS=<n>    (default: nproc)
#         MAKE_V=s          (optional: verbose OpenWrt build log)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work/openwrt}"
JOBS="${BUILD_JOBS:-$(nproc)}"

[ -f "${WORK_DIR}/.config" ] || { echo "ERROR: run scripts/prepare.sh first" >&2; exit 1; }

log() { printf '[%s] ==> %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

cd "${WORK_DIR}"

log "[DEFCONFIG]"
make defconfig

log "Saving sanitized config (diffconfig) for build metadata"
./scripts/diffconfig.sh > "${WORK_DIR}/../config.buildinfo"

log "[CONFIG VERIFY]"
bash "${REPO_ROOT}/scripts/verify-config.sh" "${WORK_DIR}" base

log "[DOWNLOAD] (-j${JOBS})"
make download -j"${JOBS}"
BROKEN="$(find dl -type f -size -1024c -print)"
if [ -n "${BROKEN}" ]; then
    log "deleting incomplete downloads and retrying:"; echo "${BROKEN}"
    echo "${BROKEN}" | xargs -r rm -f
    make download -j"${JOBS}"
fi

log "[COMPILE] (-j${JOBS})"
if ! make ${MAKE_V:+V="${MAKE_V}"} -j"${JOBS}"; then
    log "parallel build failed - re-running with -j1 V=s so the exact error is visible"
    make V=s -j1
fi

log "[CUSTOM VERIFY]"
bash "${REPO_ROOT}/scripts/verify-images.sh" "${WORK_DIR}/bin/targets/ramips/mt7621"

log "build.sh done"
