#!/bin/sh
# benchmark-iperf.sh - repeatable iperf3 throughput runs with system snapshots.
# Read-only w.r.t. router config; generates traffic only. Raw JSON kept for
# report.sh (stats are computed there, not here).
#
# usage: benchmark-iperf.sh -s SERVER [-p PORT] [-d down|up|both] [-r RUNS]
#                           [-t SECS] [-P "1 4 8"] [-o OUTDIR]
set -u
. "$(dirname "$0")/lib-hw.sh"

SERVER="" ; PORT=5201 ; DIR="both" ; RUNS=3 ; SECS=10 ; STREAMS="1 4 8" ; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -s) SERVER="$2"; shift 2 ;; -p) PORT="$2"; shift 2 ;;
        -d) DIR="$2"; shift 2 ;;    -r) RUNS="$2"; shift 2 ;;
        -t) SECS="$2"; shift 2 ;;   -P) STREAMS="$2"; shift 2 ;;
        -o) OUT="$2"; shift 2 ;;
        *) hw_die "unknown arg: $1" ;;
    esac
done
[ -n "$SERVER" ] || hw_die "-s SERVER required"
have iperf3 || hw_die "iperf3 not installed (full flavor)"
[ -n "$OUT" ] || OUT="$(hw_run_dir iperf)"
mkdir -p "$OUT"

{
    echo "tool=benchmark-iperf.sh"
    echo "started=$(iso_now)"
    echo "server=$SERVER port=$PORT dir=$DIR runs=$RUNS secs=$SECS streams='$STREAMS'"
    echo "offload_mode=$(offload_get)"
} > "$OUT/manifest.txt"
snapshot_sys "$OUT/snapshots.txt"

for dir in $DIR; do
    case "$dir" in down|up) ;; both) continue ;; *) hw_die "-d must be down|up|both" ;; esac
done

for dir in down up; do
    [ "$DIR" = "both" ] || [ "$DIR" = "$dir" ] || continue
    for p in $STREAMS; do
        run=1
        while [ "$run" -le "$RUNS" ]; do
            f="$OUT/iperf-${dir}-P${p}-run${run}.json"
            rev=""
            [ "$dir" = "down" ] && rev="-R"
            hw_log "iperf3 $dir P=$p run $run/$RUNS (${SECS}s)"
            # shellcheck disable=SC2086
            iperf3 -c "$SERVER" -p "$PORT" -t "$SECS" -P "$p" $rev -J > "$f" 2>"$f.err" \
                || hw_log "run failed (see $f.err)"
            run=$((run + 1))
        done
    done
done
snapshot_sys "$OUT/snapshots.txt"
echo "finished=$(iso_now)" >> "$OUT/manifest.txt"
hw_log "done: $OUT"
