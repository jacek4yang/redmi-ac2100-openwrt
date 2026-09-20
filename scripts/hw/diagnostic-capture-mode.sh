#!/bin/sh
# diagnostic-capture-mode.sh - reversible packet-capture-safe mode.
#
# Background: on MT7621 + PPPoE + HARDWARE flow offload, attaching packet
# sockets (tcpdump) has been linked to crashes/watchdog resets in upstream
# reports (see docs/known-issues.md). This script makes capture sessions
# explicit, logged and reversible:
#
#   enter   - disable HARDWARE flow offload (fw4), commit, restart firewall.
#             --full also disables software offload (maximum visibility).
#   exit    - restore the exact previous offload state. Idempotent.
#   status  - show whether diagnostic mode is active.
#   capture [iface] [seconds]
#           - run tcpdump with a hard timeout; default iface br-lan.
#             br-lan/lan* are always allowed. pppoe-wan additionally requires
#             --i-understand-wan-risk. Raw WAN/ethernet devices (wan, eth*,
#             DSA ports) are REFUSED: upstream issue openwrt/openwrt#24459
#             (OPEN, affects 25.12.5) crashed on the underlying ethernet
#             device even with hw offload already disabled, while pppoe-wan
#             with hw offload off was stable.
#
# Cost note: enter/exit each perform one small `uci commit` of the firewall
# config (two tiny jffs2 overlay writes per session). State file lives in
# /tmp (tmpfs). Nothing else is changed; flash layout is never touched.
set -u
. "$(dirname "$0")/lib-hw.sh"

STATE="${HW_BASE}/diag-capture.state"
FULL="${HW_BASE}/diag-capture.full"
mkdir -p "$HW_BASE"

cmd="${1:-status}"
case "$cmd" in --full) FULL_FLAG=1; cmd="${2:-status}" ;; *) FULL_FLAG=0 ;; esac

is_diag() { [ -f "$STATE" ]; }

do_enter() {
    if is_diag; then
        hw_log "diagnostic mode already active (state: $(cat "$STATE")); nothing to do"
        exit 2
    fi
    have nft || hw_die "this procedure assumes fw4/nftables; nft not found"
    offload_state_save "$STATE"
    [ "$FULL_FLAG" = 1 ] && touch "$FULL"
    if [ "$FULL_FLAG" = 1 ]; then
        offload_apply off
    else
        offload_apply sw
    fi
    hw_log "diagnostic capture mode ACTIVE (hw offload off$( [ "$FULL_FLAG" = 1 ] && echo ', sw offload off too'))"
    hw_log "run your capture, then: $0 exit"
}

do_exit() {
    rm -f "$FULL"
    offload_state_restore "$STATE"
    hw_log "diagnostic capture mode ended"
}

do_capture() {
    is_diag || hw_die "not in diagnostic mode - run '$0 enter' first"
    ifc="${1:-br-lan}"
    secs="${2:-30}"
    case "$ifc" in
        br-lan|lan*) : ;;
        pppoe-wan)
            [ "${3:-}" = "--i-understand-wan-risk" ] || \
                hw_die "pppoe-wan capture requires --i-understand-wan-risk as 3rd arg (docs/known-issues.md)"
            ;;
        wan|eth*|dsa*|*-wan)
            hw_die "raw WAN/ethernet capture refused: openwrt/openwrt#24459 crashed there even with hw offload off - use pppoe-wan instead"
            ;;
        *) hw_die "unrecognized interface '$ifc'" ;;
    esac
    case "$secs" in ''|*[!0-9]*) hw_die "seconds must be numeric" ;; esac
    [ "$secs" -le 300 ] || hw_die "cap capture length at 300s (tmpfs + safety)"
    have tcpdump || hw_die "tcpdump not installed (full flavor: tcpdump-mini)"
    out="${HW_BASE}/capture-$(date -u +%Y%m%d-%H%M%SZ)-${ifc}.pcap"
    hw_log "capturing on $ifc for ${secs}s -> $out"
    timeout "$secs" tcpdump -i "$ifc" -U -w "$out" 2>&1 | tail -5 || true
    hw_log "capture finished: $(ls -la "$out" 2>/dev/null)"
}

case "$cmd" in
    enter)   do_enter ;;
    exit)    do_exit ;;
    status)
        if is_diag; then
            echo "diagnostic capture mode: ACTIVE (saved mode: $(cat "$STATE"), current: $(offload_get))"
        else
            echo "diagnostic capture mode: inactive (current offload mode: $(offload_get))"
        fi
        ;;
    capture) shift; do_capture "$@" ;;
    *) echo "usage: $0 [--full] {enter|exit|status|capture [iface] [seconds] [--i-understand-wan-risk]}" >&2; exit 2 ;;
esac
