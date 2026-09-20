#!/bin/sh
# collect-offload.sh - read-only flow-offload / PPE / NAT fast-path capture.
# No changes, no flash. Focused on: fw4 offload config, nft flowtables,
# MTK PPE debug state, conntrack hardware-offload evidence.
set -u
. "$(dirname "$0")/lib-hw.sh"

OUT="$(hw_run_dir offload)"
hw_log "writing offload capture to $OUT"

# UCI firewall config (redacted just in case).
uci export firewall 2>/dev/null | redact > "$OUT/uci-firewall.txt" || true

# Effective nft state (flowtables + offload flags).
have nft && save_cmd "$OUT/nft-flowtables.txt" nft list flowtables
have nft && { nft list ruleset 2>/dev/null | grep -n -A6 'flowtable' > "$OUT/nft-ruleset-flowtable-excerpt.txt" || true; }
have fw4 && save_cmd "$OUT/fw4-print.txt" fw4 print

# MTK PPE debugfs (mainline mtk_eth_soc; absent when debugfs unmounted).
if [ -d /sys/kernel/debug/ppe0 ]; then
    for f in entries bind; do
        [ -r "/sys/kernel/debug/ppe0/$f" ] && cp "/sys/kernel/debug/ppe0/$f" "$OUT/ppe0-$f.txt"
    done
    ls /sys/kernel/debug/ > "$OUT/debugfs-list.txt"
else
    echo "ppe0 debugfs not present (mount -t debugfs none /sys/kernel/debug)" > "$OUT/ppe0-absent.txt"
fi

# Conntrack hardware-offload evidence.
if have conntrack; then
    save_cmd "$OUT/conntrack-offload-count.txt" sh -c '
        total=$(conntrack -L 2>/dev/null | grep -c conntrack)
        hw=$(conntrack -L 2>/dev/null | grep -c "OFFLOAD")
        echo "conntrack_total=$total"
        echo "conntrack_with_OFFLOAD_flag=$hw"
    '
    conntrack -L 2>/dev/null | grep "OFFLOAD" | head -20 > "$OUT/conntrack-offload-sample.txt" || true
fi

# WAN/PPPoE state.
have ubus && save_cmd "$OUT/ubus-wan.txt" ubus call network.interface.wan status
save_cmd "$OUT/ppp-interfaces.txt" sh -c 'ip -o link | grep -i ppp; ip addr show dev pppoe-wan 2>/dev/null'

hw_log "done: $OUT"
