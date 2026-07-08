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
err() { printf '%s\n' "$*" >&2; }

# 1. The binary runs and links (catches a broken apk install / missing libs).
if ! ver=$(keepalived --version 2>&1); then
  err "FAIL: 'keepalived --version' did not run"
  err "$ver"
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
bad=$(mktemp)
trap 'rm -f "$conf" "$bad"' EXIT
cp "$d/keepalived.conf" "$conf"
chmod 0644 "$conf"
out=$(keepalived -t -f "$conf" --log-console --log-detail 2>&1) || {
  err "FAIL: 'keepalived -t' rejected a valid VRRP config"
  err "$out"
  fail=1
}
if printf '%s' "$out" | grep -q 'skipping'; then
  err "FAIL: 'keepalived -t' skipped the config file instead of parsing it"
  err "$out"
  fail=1
fi

# 2a. Negative control: the same config minus `script_user root` must be
#     REJECTED (enable_script_security then finds no keepalived_script user,
#     rc 5). Proves -t can actually reject a bad config, independent of any
#     log-message wording — the backstop if upstream ever reworks the
#     'skipping' notice the grep above relies on.
grep -v 'script_user root' "$d/keepalived.conf" >"$bad"
chmod 0644 "$bad"
if keepalived -t -f "$bad" --log-console --log-detail >/dev/null 2>&1; then
  err "FAIL: 'keepalived -t' accepted a config it should reject (vacuous gate?)"
  fail=1
fi

[ "$fail" -eq 0 ] && log "keepalived smoke: ok"
exit "$fail"
