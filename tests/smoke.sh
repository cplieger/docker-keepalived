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
if ! keepalived --version >/dev/null 2>&1; then
	log "FAIL: 'keepalived --version' did not run"
	fail=1
fi

# 2. keepalived's own config-test mode (-t) accepts a valid VRRP config.
#    The config enables enable_script_security, which makes keepalived
#    security-check the config FILE itself: if it is group/world-writable or
#    executable, keepalived silently skips it ("not a regular non-executable
#    file - skipping") and -t exits 0 without parsing anything — a vacuous
#    pass. Build contexts on some filesystems (e.g. Windows/WSL bind mounts)
#    expose 0777, so copy to a root-owned 0644 temp file first to guarantee
#    the config is actually parsed. Also fail if keepalived reports skipping.
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

[ "$fail" -eq 0 ] && log "keepalived smoke: ok"
exit "$fail"
