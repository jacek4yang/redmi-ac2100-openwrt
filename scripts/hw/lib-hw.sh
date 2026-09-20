#!/bin/sh
# lib-hw.sh - shared helpers for the Redmi AC2100 hardware test toolkit.
# Target: OpenWrt ash (POSIX sh). No bashisms. No flash writes by itself.
# Sourced by the other scripts/hw/*.sh; not meant to be executed directly.

HW_BASE="${HW_BASE:-/tmp/ac2100-hw}"

hw_log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
hw_die()  { hw_log "ERROR: $*" >&2; exit 1; }
have()    { command -v "$1" >/dev/null 2>&1; }

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# New timestamped run directory; prints the path.
hw_run_dir() {
    _hrd_tag="${1:-run}"
    _hrd_dir="${HW_BASE}/$(date -u +%Y%m%d-%H%M%SZ)-${_hrd_tag}"
    mkdir -p "$_hrd_dir" || hw_die "cannot create $_hrd_dir"
    printf '%s\n' "$_hrd_dir"
}

# Run a command, capturing stdout+stderr+rc into $outfile with a header.
# Never fails the caller: rc is recorded, function returns 0.
save_cmd() {
    _sc_out="$1"; shift
    {
        printf '# %s\n# cmd:' "$(iso_now)"
        printf ' %s' "$@"
        printf '\n'
        "$@" 2>&1
        printf '# rc=%s\n' "$?"
    } > "$_sc_out" 2>&1 || true
}

# Redact credential-shaped values from uci/config-style output on stdin.
redact() {
    sed -E 's/^(([^=]*)(psk|key|password|secret|token|auth)([^=]*)=).*/\1<redacted>/I; s/^(\s*option\s+(psk|key|password|secret|token|auth)[^ ]*\s+).*/\1<redacted>/I'
}

# Compact runtime snapshot appended to $1 (one call ~= one sample block).
snapshot_sys() {
    _ss_out="$1"
    {
        printf -- '--- %s ---\n' "$(iso_now)"
        printf 'uptime: '; cat /proc/uptime 2>/dev/null
        printf 'loadavg: '; cat /proc/loadavg 2>/dev/null
        grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|Slab):' /proc/meminfo 2>/dev/null
        printf 'conntrack: %s / %s\n' \
            "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo '?')" \
            "$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo '?')"
        if [ -r /sys/kernel/debug/ppe0/entries ]; then
            printf 'ppe0_entries: %s\n' "$(grep -c . /sys/kernel/debug/ppe0/entries 2>/dev/null)"
        fi
        printf 'net_dev(rx/tx errs+drops):\n'
        awk 'NR>2 {gsub(":","",$1); printf "  %s rxerr=%s rxdrop=%s txerr=%s txdrop=%s\n", $1, $4, $5, $12, $13}' /proc/net/dev 2>/dev/null
    } >> "$_ss_out"
}

# ---- flow-offload state helpers ------------------------------------------------
# Modes: off | sw | hw. Read/set firewall.@defaults[0] via uci.
# offload_apply COMMITS and restarts the firewall: that is two small overlay
# (jffs2) writes per call, logged - see scripts/hw/README.md "flash wear".

offload_get() {
    _og_sw="$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)"
    _og_hw="$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)"
    case "${_og_sw:-0}${_og_hw:-0}" in
        11) echo hw ;;
        10) echo sw ;;
        *)  echo off ;;
    esac
}

offload_apply() {
    _oa_mode="$1"
    case "$_oa_mode" in
        off) _oa_sw=0; _oa_hw=0 ;;
        sw)  _oa_sw=1; _oa_hw=0 ;;
        hw)  _oa_sw=1; _oa_hw=1 ;;
        *)   hw_die "offload_apply: bad mode '$_oa_mode' (off|sw|hw)" ;;
    esac
    [ -x /etc/init.d/firewall ] || hw_die "no firewall init script"
    uci set firewall.@defaults[0].flow_offloading="$_oa_sw" || hw_die "uci set failed"
    uci set firewall.@defaults[0].flow_offloading_hw="$_oa_hw" || hw_die "uci set failed"
    uci commit firewall || hw_die "uci commit failed"
    /etc/init.d/firewall restart >/dev/null 2>&1 || hw_die "firewall restart failed"
    hw_log "offload mode applied: $_oa_mode (committed; firewall restarted)"
}

# Save current mode to a state file; restore it back. Files in /tmp (tmpfs).
offload_state_save()    { offload_get > "$1"; hw_log "offload state saved to $1: $(cat "$1")"; }
offload_state_restore() {
    [ -f "$1" ] || { hw_log "no offload state file $1 - nothing to restore"; return 0; }
    offload_apply "$(cat "$1")"
    rm -f "$1"
    hw_log "offload state restored from $1"
}
