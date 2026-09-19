#!/usr/bin/env bash
# imagebuild.sh - build Redmi AC2100 firmware via the official OpenWrt ImageBuilder.
#
# Usage:  scripts/imagebuild.sh <smoke|base|full>
#
# No source compilation happens here: the ImageBuilder links official
# precompiled 25.12.2 packages into the official image recipes. The tarball is
# SHA256-verified against the upstream sha256sums before extraction.
#
#   smoke = Milestone A: default profile packages + luci, no files/ overlay
#   base  = Milestone B: smoke + config/packages-base.list + files/ overlay
#   full  = Milestone C: base  + config/packages-full.list
set -euo pipefail

OPENWRT_VERSION="25.12.2"
IB_NAME="openwrt-imagebuilder-${OPENWRT_VERSION}-ramips-mt7621.Linux-x86_64"
# From https://downloads.openwrt.org/releases/25.12.2/targets/ramips/mt7621/sha256sums
IB_SHA256="c3bc6a9713054e278a8f010ee3b64b280362c3bf753aa291c63fc9cdd2d4d3ce"
IB_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/ramips/mt7621/${IB_NAME}.tar.zst"
PROFILE="xiaomi_redmi-router-ac2100"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-${REPO_ROOT}/work}"
IB_TARBALL="${WORK_DIR}/${IB_NAME}.tar.zst"
IB_DIR="${WORK_DIR}/imagebuilder/${OPENWRT_VERSION}"

FLAVOR="${1:?usage: imagebuild.sh <smoke|base|full>}"

stage() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }

read_list() { grep -vE '^\s*(#|$)' "$1" | tr '\n' ' '; }

# ---- tarball: reuse cached copy only if its hash verifies ----------------------
stage "IB-DOWNLOAD"
mkdir -p "${WORK_DIR}"
if [ -f "${IB_TARBALL}" ] && echo "${IB_SHA256}  ${IB_TARBALL}" | sha256sum -c - >/dev/null 2>&1; then
    echo "cached tarball present, sha256 verified: ${IB_SHA256}"
else
    echo "downloading ${IB_URL}"
    curl -fL --retry 3 --retry-delay 5 -o "${IB_TARBALL}" "${IB_URL}"
    echo "${IB_SHA256}  ${IB_TARBALL}" | sha256sum -c -
fi

# ---- extract fresh each run (cheap; guarantees no stale state) -------------------
stage "IB-EXTRACT"
rm -rf "${IB_DIR}"
mkdir -p "${IB_DIR}"
tar -I zstd -xf "${IB_TARBALL}" -C "${IB_DIR}" --strip-components=1
cd "${IB_DIR}"

# ---- prove the exact profile exists ---------------------------------------------
stage "IB-PROFILE"
make info > /tmp/ib-info.txt
grep -E "^${PROFILE}:" /tmp/ib-info.txt || { echo "ERROR: profile '${PROFILE}' not in ImageBuilder" >&2; exit 1; }
echo "profile confirmed: ${PROFILE}"
if grep -qE "^xiaomi_mi-router-ac2100:" /tmp/ib-info.txt; then
    echo "note: xiaomi_mi-router-ac2100 is a separate profile; we never select it"
fi

# ---- flavor mapping ----------------------------------------------------------------
case "${FLAVOR}" in
    smoke)
        PACKAGES="$(read_list "${REPO_ROOT}/config/packages-base.list")"
        FILES_ARG=()
        ;;
    base)
        PACKAGES="$(read_list "${REPO_ROOT}/config/packages-base.list")"
        FILES_ARG=("FILES=${REPO_ROOT}/files")
        ;;
    full)
        PACKAGES="$(read_list "${REPO_ROOT}/config/packages-base.list"; read_list "${REPO_ROOT}/config/packages-full.list")"
        FILES_ARG=("FILES=${REPO_ROOT}/files")
        ;;
    *) echo "ERROR: unknown flavor '${FLAVOR}'" >&2; exit 2 ;;
esac

# ---- build ---------------------------------------------------------------------------
stage "IB-BUILD (${FLAVOR})"
echo "profile=${PROFILE}"
echo "packages='${PACKAGES}'"
[ ${#FILES_ARG[@]} -gt 0 ] && echo "files overlay=${REPO_ROOT}/files" || echo "files overlay=(none)"
make image PROFILE="${PROFILE}" PACKAGES="${PACKAGES}" "${FILES_ARG[@]}"

# ---- resolved-package audit against the generated manifest -----------------------------
stage "IB-MANIFEST-AUDIT"
BIN_DIR="bin/targets/ramips/mt7621"
MANIFEST="$(ls "${BIN_DIR}"/openwrt-*-"${PROFILE}".manifest | head -1)"
echo "manifest: ${MANIFEST}"
need_pkg() {
    grep -qE "^$1( - |$)" "${MANIFEST}" || { echo "MANIFEST-FAIL: missing package: $1" >&2; exit 1; }
}
for p in ppp ppp-mod-pppoe odhcp6c odhcpd-ipv6only firewall4 luci kmod-mt7603 kmod-mt7615-firmware; do
    need_pkg "$p"
done
if [ "${FLAVOR}" = "full" ]; then
    for p in tailscale smartdns luci-app-smartdns iperf3 tcpdump-mini ethtool conntrack htop; do
        need_pkg "$p"
    done
fi
if [ "${FLAVOR}" != "full" ] && grep -qE '^tailscale( - |$)' "${MANIFEST}"; then
    echo "MANIFEST-FAIL: tailscale leaked into '${FLAVOR}' image" >&2; exit 1
fi
echo "manifest audit OK (${FLAVOR})"

# ---- artifact audit (shared validator; initramfs is the source pipeline's job) ---------
stage "IB-VERIFY"
REQUIRE_INITRAMFS=0 bash "${REPO_ROOT}/scripts/verify-images.sh" "${BIN_DIR}"

# ---- build metadata ---------------------------------------------------------------------
stage "IB-METADATA"
{
    echo "pipeline=imagebuilder"
    echo "openwrt_version=${OPENWRT_VERSION}"
    echo "imagebuilder_archive=${IB_NAME}.tar.zst"
    echo "imagebuilder_sha256=${IB_SHA256}"
    echo "profile=${PROFILE}"
    echo "flavor=${FLAVOR}"
    echo "packages_source=official precompiled 25.12.2 feeds (no source compilation)"
    echo "packages=${PACKAGES}"
    echo "build_date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "${BIN_DIR}/build-metadata.txt"
cp "${MANIFEST}" "${BIN_DIR}/packages.manifest"
echo "imagebuild.sh done (${FLAVOR})"
