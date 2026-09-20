#!/bin/sh
# collect-network.sh - read-only network subsystem capture. No changes, no flash.
# Records addressing, links, offloads, counters, IRQ/softirq state.
set -u
. "$(dirname "$0")/lib-hw.sh"

OUT="$(hw_run_dir network)"
hw_log "writing network capture to $OUT"

save_cmd "$OUT/ip-addr.txt"   ip addr
save_cmd "$OUT/ip-link-s.txt" ip -s link
save_cmd "$OUT/ip-route.txt"  ip route
save_cmd "$OUT/ip-route6.txt" ip -6 route
have bridge && save_cmd "$OUT/bridge-link.txt" bridge link
have bridge && save_cmd "$OUT/bridge-vlan.txt" bridge vlan
save_cmd "$OUT/proc-net-dev.txt" cat /proc/net/dev
save_cmd "$OUT/proc-net-snmp.txt" cat /proc/net/snmp
save_cmd "$OUT/interrupts.txt"   cat /proc/interrupts
save_cmd "$OUT/softirqs.txt"     cat /proc/softirqs

# Per-interface details for the interfaces that exist on this box.
IFACES="$(ip -o link 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)"
for ifc in $IFACES; do
    case "$ifc" in lo|ifb*|wlan*|-*) continue ;; esac
    have ethtool || break
    save_cmd "$OUT/ethtool-$ifc.txt"  ethtool "$ifc"
    save_cmd "$OUT/ethtool-k-$ifc.txt" ethtool -k "$ifc"
    ethtool -S "$ifc" > "$OUT/ethtool-S-$ifc.txt" 2>&1 || rm -f "$OUT/ethtool-S-$ifc.txt"
done

# Conntrack summary (tool is in the full flavor; skip gracefully otherwise).
if have conntrack; then
    save_cmd "$OUT/conntrack-S.txt" conntrack -S
    save_cmd "$OUT/conntrack-count.txt" sh -c 'cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max'
fi

# Error/drop counters in one compact table.
{
    echo "# iface rxerr rxdrop txerr txdrop"
    awk 'NR>2 {gsub(":","",$1); printf "%s %s %s %s %s\n", $1, $4, $5, $12, $13}' /proc/net/dev
} > "$OUT/err-drops.txt"

hw_log "done: $OUT"
