#!/usr/bin/env bash
# verify-repo.sh - repository hygiene gate. Run before every commit and in CI.
#
# Checks (all hard-fail with exit 1):
#   1. no dump data / binary blobs / archives are tracked (or present unignored)
#   2. .gitignore actually catches dump dirs, zips, .bin, scratch and build dirs
#   3. no obvious secrets in repo files (private keys, Tailscale keys, NVRAM
#      password values, UCI passwords, real-looking MAC addresses)
#   4. the build inputs reference ONLY xiaomi_redmi-router-ac2100
#   5. required project files exist
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
err() { echo "REPO-FAIL: $*" >&2; fail=1; }
log() { printf '==> %s\n' "$*"; }

# Tracked + untracked-but-not-ignored files = exactly what a commit could pick up.
mapfile -t FILES < <(git ls-files --cached --others --exclude-standard)

# ---- 1. No dump/binary artifacts -------------------------------------------------
bad=$(printf '%s\n' "${FILES[@]}" | grep -E '(^|/)dump[^/]*(/|$)|\.(bin|zip|tar\.gz|i64|id0|id1|nam|til)$' || true)
[ -z "${bad}" ] || err "dump/binary artifacts visible to git:"$'\n'"${bad}"

# ---- 2. Ignore rules work ----------------------------------------------------------
for p in dump-test-ignore/ dump-test-ignore.zip foo.bin .local/ .cache/ build/ work/ tmp/; do
    git check-ignore -q "$p" || err "expected-ignored path is NOT ignored: $p"
done
log "ignore rules verified"

# ---- 3. Secrets scan -----------------------------------------------------------------
secrets=$(printf '%s\0' "${FILES[@]}" | xargs -0 grep -nIE \
    -e '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' \
    -e 'tskey-[A-Za-z0-9_-]{10,}' \
    -e 'nv_sys_pwd=[0-9a-fA-F]{8,}' \
    -e "option[[:space:]]+(key|password|psk)[[:space:]]+['\"][^'\"]{8,}['\"]" \
    2>/dev/null || true)
[ -z "${secrets}" ] || err "obvious secrets in repo files:"$'\n'"${secrets}"

macs=$(printf '%s\0' "${FILES[@]}" | xargs -0 grep -noiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' 2>/dev/null \
    | grep -viE '(00:00:00:00:00:00|ff:ff:ff:ff:ff:ff|11:22:33:44:55:66|aa:bb:cc:dd:ee:ff)' || true)
[ -z "${macs}" ] || err "MAC-address-looking strings (use placeholders in docs):"$'\n'"${macs}"
log "secrets scan clean"

# ---- 4. Device identity of build inputs ---------------------------------------------
grep -q 'CONFIG_TARGET_ramips_mt7621_DEVICE_xiaomi_redmi-router-ac2100=y' config/base.config \
    || err "config/base.config does not select xiaomi_redmi-router-ac2100"
if grep -R 'xiaomi_mi-router-ac2100' config/ files/ 2>/dev/null; then
    err "mi-router reference inside build inputs (config/ or files/)"
fi
log "device identity verified (Redmi Router AC2100, ramips/mt7621)"

# ---- 5. Required files ------------------------------------------------------------------
for f in config/base.config config/packages-base.list config/packages-full.list \
         scripts/prepare.sh scripts/build.sh scripts/imagebuild.sh \
         scripts/verify-config.sh scripts/verify-images.sh scripts/inspect-stock.ps1 \
         .github/workflows/hygiene.yml .github/workflows/imagebuilder.yml \
         .github/workflows/source-build.yml .github/workflows/release.yml \
         README.md LICENSE docs/stock-flash-layout.md docs/performance.md docs/benchmarks.md; do
    [ -f "$f" ] || err "required file missing: $f"
done

if [ ${fail} -ne 0 ]; then
    echo "verify-repo: FAILED" >&2
    exit 1
fi
log "verify-repo: all checks passed (${#FILES[@]} files in scope)"
