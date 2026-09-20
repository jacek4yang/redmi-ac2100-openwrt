#!/bin/sh
# benchmark-offload-ab.sh - A/B/C throughput comparison of NAT fast-path modes:
#   off (no offload) -> sw (software flow offload) -> hw (hardware/PPE offload)
# TEMPORARILY changes firewall offload config (uci commit + firewall restart
# per mode) and RESTORES the original state on exit, including on Ctrl-C.
#
# usage: benchmark-offload-ab.sh -s SERVER [-m "off sw hw"] [-r RUNS] [-t SECS]
#                                  [-P "1 4 8"] [-o OUTDIR]
set -u
. "$(dirname "$0")/lib-hw.sh"

SERVER="" ; MODES="off sw hw" ; RUNS=3 ; SECS=10 ; STREAMS="1 4 8" ; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SERVER="$2"; shift 2 ;; -m) MODES="$2"; shift 2 ;;
        -r) RUNS="$2"; shift 2 ;;   -t) SECS="$2"; shift 2 ;;
        -P) STREAMS="$2"; shift 2 ;; -o) OUT="$2"; shift 2 ;;
        *) hw_die "unknown arg: $1" ;;
    esac
done
[ -n "$SERVER" ] || hw_die "-s SERVER required"
have iperf3 || hw_die "iperf3 not installed"
[ -n "$OUT" ] || OUT="$(hw_run_dir offload-ab)"
mkdir -p "$OUT"

STATE="$OUT/original-offload-mode"
offload_state_save "$STATE"
restore() { hw_log "restoring original offload mode..."; offload_state_restore "$STATE"; }
trap restore EXIT INT TERM

{
    echo "tool=benchmark-offload-ab.sh"
    echo "started=$(iso_now)"
    echo "server=$SERVER modes='$MODES' runs=$RUNS secs=$SECS streams='$STREAMS'"
    echo "original_mode=$(cat "$STATE")"
} > "$OUT/manifest.txt"

for mode in $MODES; do
    case "$mode" in off|sw|hw) ;; *) hw_die "bad mode '$mode' (off sw hw)" ;; esac
    hw_log "=== mode: $mode ==="
    offload_apply "$mode"
    sleep 3   # let firewall/flowtable settle
    mkdir -p "$OUT/$mode"
    offload-status.sh > "$OUT/$mode/offload-status.txt" 2>&1 || true
    snapshot_sys "$OUT/$mode/snapshots.txt"
    sh "$(dirname "$0")/benchmark-iperf.sh" -s "$SERVER" -d both -r "$RUNS" \
        -t "$SECS" -P "$STREAMS" -o "$OUT/$mode"
    snapshot_sys "$OUT/$mode/snapshots.txt"
done

hw_log "all modes done; results in $OUT"
