#!/bin/sh
# Build-time smoke test for docker-keepalived.
#
# Runs in the Dockerfile `test` stage, so the centralized `ci / validate`
# docker build-ability gate executes it on every PR and push (the final image
# stage depends on this stage's marker). Catches a broken keepalived build
# (missing shared libs, wrong version shipped, a dropped parity feature) and
# a config the binary rejects: the real failure modes for an image that
# compiles its payload from upstream source.
#
# Run locally:  sh tests/smoke.sh   (needs the keepalived binary on PATH;
# set KEEPALIVED_EXPECTED_VERSION=<X.Y.Z> to also run the exact-version check)
set -eu

d=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fail=0
log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

# 1. The binary runs and links (catches a broken build / missing libs).
if ! ver=$(keepalived --version 2>&1); then
  err "FAIL: 'keepalived --version' did not run"
  err "$ver"
  fail=1
fi

# 1a. Exact-version assertion: the binary must report the pinned upstream
#     version (KEEPALIVED_EXPECTED_VERSION, passed by the Dockerfile test
#     stage from ARG KEEPALIVED_VERSION; a leading "v" is stripped here).
#     Catches a fetch/extract mixup shipping the wrong release. Unset means
#     a bare local run: the check is skipped with a notice. The Dockerfile
#     guards the ARG with :? so the in-image gate can never silently skip.
if [ -n "${KEEPALIVED_EXPECTED_VERSION:-}" ]; then
  expected=${KEEPALIVED_EXPECTED_VERSION#v}
  if ! printf '%s\n' "$ver" | head -n 1 | grep -qF "Keepalived v${expected} ("; then
    err "FAIL: version mismatch: expected v${expected}, got: $(printf '%s\n' "$ver" | head -n 1)"
    fail=1
  fi
else
  log "note: KEEPALIVED_EXPECTED_VERSION unset - skipping exact-version check (local run)"
fi

# 1b. Feature-parity assertion: the build must include nftables and JSON
#     support (parity with Alpine's community keepalived package). keepalived
#     lists its compiled-in features on --version's "Config options" line;
#     a configure that silently dropped a feature fails here.
for feat in NFTABLES JSON; do
  if ! printf '%s\n' "$ver" | grep -qw "$feat"; then
    err "FAIL: keepalived built without $feat support (parity floor)"
    fail=1
  fi
done

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
if bad_out=$(keepalived -t -f "$bad" --log-console --log-detail 2>&1); then
  err "FAIL: 'keepalived -t' accepted a config it should reject (vacuous gate?)"
  err "$bad_out"
  fail=1
fi

[ "$fail" -eq 0 ] && log "keepalived smoke: ok"
exit "$fail"
