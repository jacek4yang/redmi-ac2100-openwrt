#!/usr/bin/env bash
# build.sh - expand config, download sources, compile, verify artifacts.
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

log() { printf '==> %s\n' "$*"; }

cd "${WORK_DIR}"

log "make defconfig"
make defconfig

log "Saving sanitized config (diffconfig) for release metadata"
./scripts/diffconfig.sh > "${WORK_DIR}/../config.buildinfo"

log "make download (-j${JOBS})"
make download -j"${JOBS}"

log "make (-j${JOBS})"
make ${MAKE_V:+V="${MAKE_V}"} -j"${JOBS}"

log "Verifying generated images"
"${REPO_ROOT}/scripts/verify-images.sh" "${WORK_DIR}/bin/targets/ramips/mt7621"

log "build.sh done"
