#!/bin/sh
# Build-time smoke test for docker-keepalived.
#
# Runs in the Dockerfile `test` stage, so the centralized `ci / validate`
# docker build-ability gate executes it on every PR and push (the final image
# stage depends on this stage's marker). Catches a broken keepalived package
# (missing shared libs, unparseable build) and a config the binary rejects —
# the real failure modes for a thin upstream-wrapper image.
#
# Run locally:  sh tests/smoke.sh   (needs the keepalived binary on PATH)
set -eu

d=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fail=0
log() { printf '%s\n' "$*"; }

# 1. The binary runs and links (catches a broken apk install / missing libs).
if ! ver=$(keepalived --version 2>&1); then
  log "FAIL: 'keepalived --version' did not run"
  log "$ver"
  fail=1
fi

# 2. keepalived's own config-test mode (-t) accepts a valid VRRP config.
#    The config enables enable_script_security, which makes keepalived
#    security-check the config FILE itself: keepalived skips (does not
#    parse) any config file that is not a regular file or has any execute
#    bit set ("not a regular non-executable file - skipping"), and -t then
#    exits 0 without parsing anything - a vacuous pass. Build contexts on
#    some filesystems (e.g. Windows/WSL bind mounts) expose 0777, whose
#    execute bits trigger the skip, so copy to a root-owned 0644 temp file
#    first to guarantee the config is actually parsed. Also fail if
#    keepalived reports skipping. (The writable-bit "Unsafe permissions"
#    check is a separate path that applies to track/notify SCRIPTS, not the
#    config file.)
conf=$(mktemp)
trap 'rm -f "$conf"' EXIT
cp "$d/keepalived.conf" "$conf"
chmod 0644 "$conf"
out=$(keepalived -t -f "$conf" --log-console --log-detail 2>&1) || {
  log "FAIL: 'keepalived -t' rejected a valid VRRP config"
  log "$out"
  fail=1
}
if printf '%s' "$out" | grep -q 'skipping'; then
  log "FAIL: 'keepalived -t' skipped the config file instead of parsing it"
  log "$out"
  fail=1
fi
# Defense-in-depth: confirm the file was actually opened/parsed. keepalived's
# open_conf_file() logs "Opening file '<path>'." under --log-detail, so its
# absence means -t never parsed the config (guards against a future vacuous
# pass if the 'skipping' wording ever changes upstream).
if ! printf '%s' "$out" | grep -q 'Opening file'; then
  log "FAIL: 'keepalived -t' logged no 'Opening file' - config may not have been parsed"
  log "$out"
  fail=1
fi

[ "$fail" -eq 0 ] && log "keepalived smoke: ok"
exit "$fail"
