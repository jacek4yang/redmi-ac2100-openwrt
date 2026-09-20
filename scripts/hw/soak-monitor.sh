#!/bin/sh
# soak-monitor.sh - long-running stability sampler with anomaly detection.
# Read-only. Samples load/memory/conntrack/PPE/counters at a modest interval
# (monitoring must not change the result). Flags kernel oops/warnings/OOM/
# watchdog and error-counter growth. Exit 0 = clean, 2 = anomalies found.
#
# usage: soak-monitor.sh [-i INTERVAL_S] [-d DURATION] [-o OUTDIR]
#   DURATION accepts s/m/h suffix, e.g. 30m 2h 8h 24h 72h (default 8h)
set -u
. "$(dirname "$0")/lib-hw.sh"

INTERVAL=30 ; DUR="8h" ; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -i) INTERVAL="$2"; shift 2 ;; -d) DUR="$2"; shift 2 ;;
        -o) OUT="$2"; shift 2 ;;
        *) hw_die "unknown arg: $1" ;;
    esac
done
SECS=$(awk -v d="$DUR" 'BEGIN{
    u=substr(d, length(d)); n=substr(d, 1, length(d)-1);
    if (u=="s") print n; else if (u=="m") print n*60;
    else if (u=="h") print n*3600; else print 0 }')
[ "$SECS" -gt 0 ] || hw_die "bad duration '$DUR' (use 30m/2h/8h/24h/72h)"
[ -n "$OUT" ] || OUT="$(hw_run_dir soak)"
mkdir -p "$OUT"

hw_log "soak: interval=${INTERVAL}s duration=${DUR} out=$OUT"
echo "tool=soak-monitor.sh interval=$INTERVAL duration=$DUR started=$(iso_now)" > "$OUT/manifest.txt"
: > "$OUT/anomalies.log"

prev_err="$(awk 'NR>2 {s+=$4+$5+$12+$13} END {print s+0}' /proc/net/dev)"
dmesg_seen=0
end=$(( $(cut -d. -f1 /proc/uptime) + SECS ))
anom=0

while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
    snapshot_sys "$OUT/samples.txt"
    # bound disk usage (tmpfs!): stop sampling if dir grows past 16M
    used="$(du -sm "$OUT" 2>/dev/null | cut -f1)"
    if [ "${used:-0}" -gt 16 ]; then hw_log "output >16M, stopping sampler"; break; fi

    # anomaly 1: new scary dmesg lines
    total="$(dmesg 2>/dev/null | grep -cE 'Oops|BUG:|WARNING:|Out of memory|watchdog|rcu_sched|hang|stall' || true)"
    if [ "${total:-0}" -gt "$dmesg_seen" ]; then
        dmesg | grep -E 'Oops|BUG:|WARNING:|Out of memory|watchdog|rcu_sched|hang|stall' | tail -n +"$((dmesg_seen + 1))" >> "$OUT/anomalies.log" 2>/dev/null
        dmesg_seen="$total"; anom=1
        hw_log "ANOMALY: kernel warnings/oops detected (see anomalies.log)"
    fi

    # anomaly 2: error/drop counter jumps
    now_err="$(awk 'NR>2 {s+=$4+$5+$12+$13} END {print s+0}' /proc/net/dev)"
    delta=$((now_err - prev_err)); prev_err="$now_err"
    if [ "$delta" -gt 100 ]; then
        echo "$(iso_now) iface err/drop delta=$delta" >> "$OUT/anomalies.log"
        anom=1; hw_log "ANOMALY: err/drop delta=$delta"
    fi

    # anomaly 3: conntrack near exhaustion
    ct="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)"
    ctm="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 1)"
    [ "$ct" -gt $((ctm * 9 / 10)) ] && { echo "$(iso_now) conntrack $ct/$ctm >90%" >> "$OUT/anomalies.log"; anom=1; }

    sleep "$INTERVAL"
done

echo "finished=$(iso_now) anomalies=$anom" >> "$OUT/manifest.txt"
hw_log "soak finished: anomalies=$anom ($OUT)"
[ "$anom" -eq 0 ] || exit 2
