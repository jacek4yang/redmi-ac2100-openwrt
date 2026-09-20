#!/bin/sh
# benchmark-pppoe.sh - bounded PPPoE reconnect stability test.
# TEMPORARILY cycles the wan interface: ifdown/ifup per cycle, then verifies
# session, route and DNS recovery. Leaves wan UP on abort.
#
# Default assumes a LAB PPPoE server on the WAN port. Against a live ISP,
# pass --live-isp (be polite: <= 50 cycles, >= 20s between attempts).
#
# usage: benchmark-pppoe.sh [-n CYCLES] [--live-isp] [-o OUTDIR]
set -u
. "$(dirname "$0")/lib-hw.sh"

CYCLES=20 ; LIVE=0 ; OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n) CYCLES="$2"; shift 2 ;;
        --live-isp) LIVE=1; shift ;;
        -o) OUT="$2"; shift 2 ;;
        *) hw_die "unknown arg: $1" ;;
    esac
done
case "$CYCLES" in ''|*[!0-9]*) hw_die "CYCLES must be numeric" ;; esac
[ "$CYCLES" -le 200 ] || hw_die "refusing >200 cycles"
[ "$(uci -q get network.wan.proto 2>/dev/null)" = "pppoe" ] || hw_die "network.wan.proto is not pppoe"
if [ "$LIVE" != 1 ]; then
    gw="$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')"
    case "$gw" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|"") : ;; *)
        hw_die "default gateway $gw looks public - pass --live-isp if you really mean it" ;;
    esac
fi
[ -n "$OUT" ] || OUT="$(hw_run_dir pppoe)"
mkdir -p "$OUT"

abort() { hw_log "aborted - bringing wan back up"; ifup wan >/dev/null 2>&1; exit 3; }
trap abort INT TERM

hw_log "starting $CYCLES pppoe reconnect cycles (live-isp=$LIVE)"
echo "# cycle down_at up_after_s route_ok dns_ok conntrack" > "$OUT/cycles.csv"
ok=0; fail=0
n=1
while [ "$n" -le "$CYCLES" ]; do
    ifdown wan >/dev/null 2>&1
    sleep 3
    ifup wan >/dev/null 2>&1
    # wait for session: pppoe-wan has an inet addr, <= 60s
    up_s=""
    i=0
    while [ "$i" -lt 60 ]; do
        if ip addr show dev pppoe-wan 2>/dev/null | grep -q 'inet '; then up_s="$i"; break; fi
        sleep 1; i=$((i + 1))
    done
    route_ok=0; dns_ok=0
    if [ -n "$up_s" ]; then
        ip route 2>/dev/null | grep -q '^default' && route_ok=1
        nslookup openwrt.org >/dev/null 2>&1 && dns_ok=1
    fi
    ct="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo '?')"
    echo "$n $(iso_now) ${up_s:-timeout} $route_ok $dns_ok $ct" >> "$OUT/cycles.csv"
    if [ -n "$up_s" ] && [ "$route_ok" = 1 ] && [ "$dns_ok" = 1 ]; then
        ok=$((ok + 1))
    else
        fail=$((fail + 1))
        hw_log "cycle $n: FAILURE up=${up_s:-timeout} route=$route_ok dns=$dns_ok"
        save_cmd "$OUT/failure-cycle-$n.txt" sh -c 'ip addr; ip route; logread | tail -40'
    fi
    [ "$LIVE" = 1 ] && sleep 17   # >=20s between attempts against real ISPs
    n=$((n + 1))
done
snapshot_sys "$OUT/snapshot-end.txt"
echo "result: ok=$ok fail=$fail cycles=$CYCLES" | tee "$OUT/summary.txt"
[ "$fail" -eq 0 ]
