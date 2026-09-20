#!/bin/sh
# benchmark-latency.sh - latency distribution to a host, optionally under load.
# Read-only. usage: benchmark-latency.sh -H HOST [-c COUNT] [-i INTERVAL] [-o OUTDIR]
# Start it before benchmark-iperf.sh to get latency-under-load samples.
set -u
. "$(dirname "$0")/lib-hw.sh"

HOST="" ; COUNT=100 ; INTERVAL="0.2" ; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -H) HOST="$2"; shift 2 ;; -c) COUNT="$2"; shift 2 ;;
        -i) INTERVAL="$2"; shift 2 ;; -o) OUT="$2"; shift 2 ;;
        *) hw_die "unknown arg: $1" ;;
    esac
done
[ -n "$HOST" ] || hw_die "-H HOST required"
[ -n "$OUT" ] || OUT="$(hw_run_dir latency)"
mkdir -p "$OUT"

hw_log "ping $HOST count=$COUNT interval=$INTERVAL"
ping -c "$COUNT" -i "$INTERVAL" "$HOST" > "$OUT/ping.txt" 2>&1 || hw_log "ping had losses/failures (see ping.txt)"

# busybox/iputils ping both end with a 'round-trip ... min/avg/max(/mdev)' line.
awk '/round-trip|rtt/ {print}' "$OUT/ping.txt" > "$OUT/ping-summary.txt"
grep -E 'packets transmitted' "$OUT/ping.txt" >> "$OUT/ping-summary.txt" 2>/dev/null || true

# Per-reply distribution (time= ms values) for percentiles on the PC side.
grep -oE 'time=[0-9.]+' "$OUT/ping.txt" | cut -d= -f2 > "$OUT/ping-samples.txt" || true
hw_log "done: $OUT ($(wc -l < "$OUT/ping-samples.txt" 2>/dev/null || echo 0) samples)"
