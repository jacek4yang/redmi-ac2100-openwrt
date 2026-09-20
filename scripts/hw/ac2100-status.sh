#!/bin/sh
# ac2100-status.sh - one-shot human-readable router status dashboard.
# Read-only. Fast enough to run any time.
set -u
. "$(dirname "$0")/lib-hw.sh"

echo "================ Redmi AC2100 status ================"
grep -E 'DISTRIB_(DESCRIPTION|RELEASE|REVISION)' /etc/openwrt_release 2>/dev/null
printf 'uptime: %s' "$(uptime)"
printf 'memory: '; awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d/%d kB available (%.0f%%)\n", a, t, a/t*100}' /proc/meminfo

echo
echo "-- WAN --"
if have ubus; then
    ubus call network.interface.wan status 2>/dev/null | \
        grep -E '"(up|proto|device|uptime)"' | sed 's/^[[:space:]]*//'
fi
ip addr show dev pppoe-wan 2>/dev/null | awk '/inet / {print "pppoe-wan:", $2}'

echo
echo "-- NAT fast path --"
echo "offload mode: $(offload_get)"
if [ -r /sys/kernel/debug/ppe0/entries ]; then
    echo "ppe0 entries: $(grep -c . /sys/kernel/debug/ppe0/entries)"
fi
echo "conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)/$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)"

echo
echo "-- Ethernet links --"
if have ethtool; then
    for ifc in wan lan1 lan2 lan3; do
        [ -d "/sys/class/net/$ifc" ] || continue
        sp="$(ethtool "$ifc" 2>/dev/null | awk -F': ' '/Speed/ {print $2}')"
        du="$(ethtool "$ifc" 2>/dev/null | awk -F': ' '/Duplex/ {print $2}')"
        lk="$(cat /sys/class/net/$ifc/operstate 2>/dev/null)"
        printf '  %-5s %s %s %s\n' "$ifc" "$lk" "$sp" "$du"
    done
fi

echo
echo "-- Wi-Fi --"
if have iw; then
    for ifc in $(iw dev 2>/dev/null | awk '$1=="Interface" {print $2}'); do
        ch="$(iw dev "$ifc" info 2>/dev/null | awk '/channel/ {print $2" ("$4")"}')"
        nst="$(iw dev "$ifc" station dump 2>/dev/null | grep -c '^Station')"
        printf '  %-8s channel %-12s stations %s\n' "$ifc" "${ch:-?}" "${nst:-0}"
    done
else
    echo "iw not found"
fi
echo "====================================================="
