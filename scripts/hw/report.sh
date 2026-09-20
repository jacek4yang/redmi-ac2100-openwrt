#!/bin/sh
# report.sh - summarize a results directory produced by the toolkit.
# Read-only. iperf3 statistics need jq (available on the PC side; on the
# router install the small 'jq' package or copy results to a PC).
#
# usage: report.sh RESULTS_DIR
set -u
. "$(dirname "$0")/lib-hw.sh"

DIR="${1:-}"
[ -d "$DIR" ] || hw_die "usage: report.sh RESULTS_DIR"

echo "== $DIR =="
[ -f "$DIR/manifest.txt" ] && { echo "-- manifest --"; cat "$DIR/manifest.txt"; }

jsons="$(find "$DIR" -name 'iperf-*.json' 2>/dev/null | head -100)"
if [ -n "$jsons" ]; then
    echo "-- iperf3 runs --"
    if have jq; then
        # Collect "group bps" per run; stats via external sort (busybox-safe,
        # no gawk extensions). Median = lower-middle value for even counts.
        TMPV="$DIR/.report-values.txt"
        : > "$TMPV"
        for f in $jsons; do
            bps="$(jq -r '.end.sum_received.bits_per_second // .end.sum.bits_per_second // empty' "$f" 2>/dev/null)"
            [ -n "$bps" ] && printf '%s %s\n' "$(basename "$f" .json | sed 's/-run[0-9]*$//')" "$bps" >> "$TMPV"
        done
        if [ -s "$TMPV" ]; then
            for grp in $(awk '{print $1}' "$TMPV" | sort -u); do
                vals="$(awk -v g="$grp" '$1==g {print $2}' "$TMPV" | sort -n)"
                n="$(printf '%s\n' "$vals" | wc -l)"
                mn="$(printf '%s\n' "$vals" | head -1)"
                mx="$(printf '%s\n' "$vals" | tail -1)"
                md="$(printf '%s\n' "$vals" | awk -v n="$n" 'NR==int((n+1)/2)')"
                awk -v g="$grp" -v n="$n" -v a="$mn" -v b="$md" -v c="$mx" \
                    'BEGIN{printf "%-28s runs=%d  min=%.1f  median=%.1f  max=%.1f Mbps\n", g, n, a/1e6, b/1e6, c/1e6}'
            done
        fi
        rm -f "$TMPV"
    else
        echo "(jq not available - install jq or copy this dir to a PC to compute stats)"
        echo "$jsons"
    fi
fi

[ -f "$DIR/ping-summary.txt" ] && { echo "-- latency --"; cat "$DIR/ping-summary.txt"; }
[ -f "$DIR/cycles.csv" ] && { echo "-- pppoe cycles --"; cat "$DIR/cycles.csv"; }
[ -f "$DIR/summary.txt" ] && cat "$DIR/summary.txt"
exit 0
