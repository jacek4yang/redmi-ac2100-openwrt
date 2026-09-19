#!/usr/bin/env bash
# verify-config.sh - audit the RESOLVED OpenWrt .config (after make defconfig).
#
# The seed configs are intentions; this script verifies what the build system
# actually resolved, before wasting hours compiling. Fail fast, exit 1 on any
# violation.
#
# Usage:  scripts/verify-config.sh [OPENWRT_DIR] [FLAVOR]
#         defaults: work/openwrt, full
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENWRT_DIR="${1:-${REPO_ROOT}/work/openwrt}"
FLAVOR="${2:-${FLAVOR:-full}}"
CFG="${OPENWRT_DIR}/.config"

[ -f "${CFG}" ] || { echo "ERROR: ${CFG} not found (run prepare.sh + make defconfig first)" >&2; exit 1; }

fail=0
err() { echo "CONFIG-FAIL: $*" >&2; fail=1; }
need() { grep -q "^$1=y" "${CFG}" || err "missing required symbol: $1"; }
forbid() { if grep -qE "^$1" "${CFG}"; then err "forbidden symbol present: $1"; fi; }

# ---- Device / target identity -------------------------------------------------
need CONFIG_TARGET_ramips
need CONFIG_TARGET_ramips_mt7621
need CONFIG_TARGET_ramips_mt7621_DEVICE_xiaomi_redmi-router-ac2100
if grep -q 'DEVICE_xiaomi_mi-router-ac2100=y' "${CFG}"; then
    err "resolved config selects xiaomi_mi-router-ac2100 (wrong device)"
fi

# ---- Required functionality (Phase: required functionality) ---------------------
need CONFIG_PACKAGE_ppp
need CONFIG_PACKAGE_ppp-mod-pppoe
need CONFIG_PACKAGE_firewall4
need CONFIG_PACKAGE_kmod-nft-core
need CONFIG_IPV6
need CONFIG_PACKAGE_odhcp6c
need CONFIG_PACKAGE_odhcpd-ipv6only
need CONFIG_PACKAGE_luci
need CONFIG_PACKAGE_dropbear

# ---- Radios (device package set from mt7621.mk) ---------------------------------
need CONFIG_PACKAGE_kmod-mt7603
need CONFIG_PACKAGE_kmod-mt7615-firmware

# ---- RAM-bootable recovery image (documented artifact) ---------------------------
need CONFIG_TARGET_ROOTFS_INITRAMFS

# ---- Flavor-gated packages --------------------------------------------------------
FULL_ONLY=(CONFIG_PACKAGE_tailscale CONFIG_PACKAGE_smartdns CONFIG_PACKAGE_luci-app-smartdns \
           CONFIG_PACKAGE_iperf3 CONFIG_PACKAGE_tcpdump-mini CONFIG_PACKAGE_ethtool \
           CONFIG_PACKAGE_conntrack CONFIG_PACKAGE_htop)
if [ "${FLAVOR}" = "full" ]; then
    for s in "${FULL_ONLY[@]}"; do need "$s"; done
elif [ "${FLAVOR}" = "base" ]; then
    for s in "${FULL_ONLY[@]}"; do
        if grep -q "^$s=y" "${CFG}"; then err "base flavor unexpectedly contains: $s"; fi
    done
else
    err "unknown FLAVOR '${FLAVOR}' (expected base|full)"
fi

# ---- Bloat tripwires (never wanted on this device) --------------------------------
forbid 'CONFIG_PACKAGE_samba4=y'
forbid 'CONFIG_PACKAGE_minidlna=y'
forbid 'CONFIG_PACKAGE_kmod-usb-storage=y'

if [ ${fail} -ne 0 ]; then
    echo "verify-config: FAILED (${OPENWRT_DIR}/.config, flavor=${FLAVOR})" >&2
    exit 1
fi
echo "verify-config: OK (ramips/mt7621 xiaomi_redmi-router-ac2100, flavor=${FLAVOR})"
