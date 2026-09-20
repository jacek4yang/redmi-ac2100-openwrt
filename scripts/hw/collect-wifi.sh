#!/bin/sh
# collect-wifi.sh - read-only Wi-Fi capture. REDACTS passphrases/keys.
# No changes, no flash. Radios on RM2100: phy for MT7603 (2.4) + MT7615 (5).
set -u
. "$(dirname "$0")/lib-hw.sh"

OUT="$(hw_run_dir wifi)"
hw_log "writing wifi capture to $OUT"

uci export wireless 2>/dev/null | redact > "$OUT/uci-wireless-redacted.txt" || true

have iw || hw_die "iw not found"
save_cmd "$OUT/iw-dev.txt" iw dev

for phy in $(iw dev 2>/dev/null | awk '/^phy#/ {print $1}'); do
    iw phy "$phy" info 2>/dev/null | sed -n '1,40p' > "$OUT/$phy-info-head.txt"
    iw phy "$phy" channels 2>/dev/null | head -60 > "$OUT/$phy-channels.txt"
done

# Per-interface: link, stations (signal/bitrates), current channel survey.
for ifc in $(iw dev 2>/dev/null | awk '$1=="Interface" {print $2}'); do
    save_cmd "$OUT/$ifc-info.txt" iw dev "$ifc" info
    save_cmd "$OUT/$ifc-link.txt" iw dev "$ifc" link
    iw dev "$ifc" station dump 2>/dev/null > "$OUT/$ifc-stations.txt"
    iw dev "$ifc" survey dump 2>/dev/null | sed -n '/in use/,/^$/p' > "$OUT/$ifc-survey-inuse.txt"
done

have iwinfo && save_cmd "$OUT/iwinfo.txt" iwinfo

hw_log "done: $OUT (secrets redacted; client MACs stay local - never commit raw results)"
