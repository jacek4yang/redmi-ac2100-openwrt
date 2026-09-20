#!/bin/sh
# collect-system.sh - read-only system baseline capture. No changes, no flash.
# Output: a timestamped dir under $HW_BASE (default /tmp/ac2100-hw).
set -u
. "$(dirname "$0")/lib-hw.sh"

OUT="$(hw_run_dir system)"
hw_log "writing system capture to $OUT"

save_cmd "$OUT/identity.txt" sh -c '
    echo "--- /etc/openwrt_release ---"; cat /etc/openwrt_release 2>/dev/null
    echo "--- uname ---"; uname -a
    echo "--- cmdline ---"; cat /proc/cmdline
    echo "--- date ---"; date -u
    echo "--- uptime ---"; uptime
'
save_cmd "$OUT/cpuinfo.txt"    cat /proc/cpuinfo
save_cmd "$OUT/meminfo.txt"    cat /proc/meminfo
save_cmd "$OUT/df.txt"         df -h
save_cmd "$OUT/mtd.txt"        cat /proc/mtd
save_cmd "$OUT/mounts.txt"     mount
save_cmd "$OUT/dmesg.txt"      dmesg
have logread && save_cmd "$OUT/logread.txt" logread
have opkg    && save_cmd "$OUT/packages.txt" opkg list-installed
for t in /sys/class/thermal/thermal_zone*/temp; do
    [ -r "$t" ] && echo "$t = $(cat "$t")" >> "$OUT/thermal.txt"
done
[ -f "$OUT/thermal.txt" ] || rm -f "$OUT/thermal.txt"

hw_log "done: $OUT"
