#!/bin/sh
# offload-status.sh - concise read-only view of the NAT fast-path state.
# Exit 0 always (informational). Used by ac2100-status.sh and benchmarks.
set -u
. "$(dirname "$0")/lib-hw.sh"

echo "== flow offload (uci firewall defaults) =="
echo "configured mode: $(offload_get)   (off|sw|hw)"

echo
echo "== nft flowtables =="
if have nft; then
    nft list flowtables 2>/dev/null || echo "(none)"
else
    echo "nft not found"
fi

echo
echo "== PPE (MT7621 hardware offload engine) =="
if [ -r /sys/kernel/debug/ppe0/entries ]; then
    echo "ppe0 entries: $(grep -c . /sys/kernel/debug/ppe0/entries)"
    [ -r /sys/kernel/debug/ppe0/bind ] && echo "ppe0 bind: $(grep -c . /sys/kernel/debug/ppe0/bind)"
else
    echo "ppe0 debugfs not readable (mount debugfs or not offloading)"
fi

echo
echo "== conntrack =="
echo "$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null) / $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null) entries"
if have conntrack; then
    echo "with OFFLOAD flag: $(conntrack -L 2>/dev/null | grep -c OFFLOAD)"
fi

echo
echo "== WAN =="
if have ubus; then
    ubus call network.interface.wan status 2>/dev/null | grep -E '"(up|proto|device|uptime)"' || echo "wan status unavailable"
fi
ip addr show dev pppoe-wan 2>/dev/null | grep -E 'pppoe-wan|inet ' || true
