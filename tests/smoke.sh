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
if ! keepalived -t -f "$d/keepalived.conf" --log-console >/dev/null 2>&1; then
	log "FAIL: 'keepalived -t' rejected a valid VRRP config"
	fail=1
fi

[ "$fail" -eq 0 ] && log "keepalived smoke: ok"
exit "$fail"
