#!/bin/sh
# Build-time smoke test for docker-keepalived.
#
# Runs in the Dockerfile `test` stage, and the final image stage depends on
# this stage's marker, so an image build cannot skip it. Catches a broken
# keepalived build (missing shared libs, wrong version shipped, a dropped
# parity feature), a config the binary rejects, and a missing or
# version-drifted embedded SBOM fragment: the real failure modes for an image
# that compiles its payload from upstream source.
#
# Run locally:  sh tests/smoke.sh   (needs the keepalived binary on PATH.
# Sections 1a, 1c, 3 and 4 run only when KEEPALIVED_EXPECTED_VERSION is
# set, which the Dockerfile test stage does; each skips here with a
# notice. Do not set it by hand on a host: section 3 reads the SBOM
# fragment, which ships only in this image, so it fails.)
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

# The published operator prose is scoped to the features this build compiles:
# alerts.yaml and the README name vrrp_no_swap and checker_no_swap and no BFD
# directive, because --enable-bfd is opt-in and the configure line passes
# --disable-bfd. A configure default that flipped upstream would make that
# prose incomplete with no human in the loop, so assert the absence the way
# section 1 asserts the presences.
# Keep this match case-SENSITIVE and word-bounded. $ver holds the whole
# --version output, whose first section is the literal configure command
# line, and that line now contains --disable-bfd: `grep -qiw bfd` would
# match it and fail every build. Red-checked with a stubbed
# `keepalived --version` on PATH — BFD in the Config options line fails,
# --disable-bfd on the configure options line does not.
if printf '%s\n' "$ver" | grep -qw BFD; then
  err "FAIL: build gained BFD support — alerts.yaml and README.md name no BFD directive"
  fail=1
fi

# 1c. genhash mode: the shipped /usr/bin/genhash must actually run keepalived's
#     genhash, which is a compile-time-conditional argv[0] dispatch (_WITH_LVS_),
#     not a property of the symlink. Gated like 1a/3: it reads the image filesystem.
if [ -n "${KEEPALIVED_EXPECTED_VERSION:-}" ]; then
  gh_out=$(/usr/bin/genhash -h 2>&1) || true
  if ! printf '%s\n' "$gh_out" | grep -q -- '--use-virtualhost'; then
    err "FAIL: /usr/bin/genhash does not run in genhash mode"
    err "$gh_out"
    fail=1
  fi
else
  log "note: KEEPALIVED_EXPECTED_VERSION unset - skipping genhash mode check (local run)"
fi

# 2. keepalived's own config-test mode (-t) accepts a valid VRRP config.
#    keepalived checks every config file before parsing it, independent of
#    enable_script_security: it skips (does not parse) any config file that
#    is not a regular file or has any execute bit set ("not a regular
#    non-executable file - skipping"), and -t then exits 0 without parsing
#    anything - a vacuous pass. Build contexts on some filesystems (e.g.
#    Windows/WSL bind mounts) expose 0777, whose execute bits trigger the
#    skip, so copy to a root-owned 0644 temp file first to guarantee the
#    config is actually parsed. (The writable-bit "Unsafe permissions"
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

# 2a. Negative control: the same config minus `script_user root` must be
#     REJECTED (enable_script_security then finds no keepalived_script user,
#     rc 5). Proves -t can actually reject a bad config, independent of any
#     log-message wording — the wording-independent guard against a vacuous
#     -t pass (a skipped config file exits 0 without parsing, and a skipped
#     bad config fails this check).
grep -v 'script_user root' "$d/keepalived.conf" >"$bad"
chmod 0644 "$bad"
if bad_out=$(keepalived -t -f "$bad" --log-console --log-detail 2>&1); then
  err "FAIL: 'keepalived -t' accepted a config it should reject (vacuous gate?)"
  err "$bad_out"
  fail=1
fi

# 3. Embedded SBOM fragment (Dockerfile builder stage): the CycloneDX file
#    covering the source-built keepalived must ship in the image, name the
#    component, and carry the ARG-derived version — a hardcoded version
#    would drift silently on the next Renovate bump, which is exactly the
#    failure mode the fragment exists to prevent. Gated on
#    KEEPALIVED_EXPECTED_VERSION like section 1a: in-image the Dockerfile's
#    :? guard guarantees the variable, so the gate can never silently skip;
#    a bare local run (no image filesystem) skips with a notice. The
#    Dockerfile test stage installs jq for the parse below; the runtime
#    image ships none.
if [ -n "${KEEPALIVED_EXPECTED_VERSION:-}" ]; then
  sbom=/usr/share/sbom/keepalived.cdx.json
  expected=${KEEPALIVED_EXPECTED_VERSION#v}
  if [ ! -s "$sbom" ]; then
    err "FAIL: embedded SBOM fragment missing or empty: $sbom"
    fail=1
  else
    # Every assertion accumulates into $fail instead of aborting, so a
    # malformed fragment still leaves section 4's result in the build log.
    jq -e . "$sbom" >/dev/null || {
      err "FAIL: embedded SBOM fragment is not valid JSON: $sbom"
      fail=1
    }
    jq -e '.components | length == 1' "$sbom" >/dev/null || {
      err "FAIL: embedded SBOM fragment does not carry exactly one component"
      fail=1
    }
    jq -e '.components[0].name == "keepalived"' "$sbom" >/dev/null || {
      err "FAIL: embedded SBOM fragment component is not named keepalived"
      fail=1
    }
    jq -e --arg want "$expected" '.components[0].version == $want' "$sbom" >/dev/null || {
      err "FAIL: embedded SBOM fragment version is not v${expected} (ARG wiring broken?)"
      fail=1
    }
    # The purl is asserted whole: both provenance qualifiers interpolate the
    # same build ARGs the test stage passes in, so a hand-edited literal in
    # the Dockerfile's heredoc cannot outlive a version or checksum bump
    # unnoticed.
    purl="pkg:generic/keepalived@${expected}?download_url=https://www.keepalived.org/software/keepalived-${expected}.tar.gz&checksum=sha256:${KEEPALIVED_EXPECTED_SHA256:-}"
    jq -e --arg want "$purl" '.components[0].purl == $want' "$sbom" >/dev/null || {
      err "FAIL: embedded SBOM fragment purl is not ${purl} (provenance lost?)"
      fail=1
    }
    jq -e --arg want "cpe:2.3:a:keepalived:keepalived:${expected}:*:*:*:*:*:*:*" \
      '.components[0].cpe == $want' "$sbom" >/dev/null || {
      err "FAIL: embedded SBOM fragment cpe is not cpe:2.3:a:keepalived:keepalived:${expected}:*:*:*:*:*:*:*"
      fail=1
    }
  fi
else
  log "note: KEEPALIVED_EXPECTED_VERSION unset - skipping SBOM fragment check (local run)"
fi

# 4. Alert-matcher anchors: the discriminating literals alerts.yaml keys
#    on must still exist in the binary this image ships. The rule pack
#    matches upstream's log wording, KEEPALIVED_VERSION bumps automerge,
#    and nothing else re-reads the matchers, so a reworded format string
#    would decouple the published rules from the running daemon with no
#    human in the loop. Keep this list in step with alerts.yaml.
#    Deliberately NOT covered: KeepalivedTrackScriptFailed's `failed`
#    status word. Upstream assigns it to script_exit_type separately from
#    the "VRRP_Script(%s) %s" format string it is substituted into, so
#    anchoring the format string certifies nothing about it - which is why
#    `timed_out` needs its own entry below - and the binary carries
#    unrelated strings containing "failed", so `grep -qF -- 'failed'` is
#    an assertion that cannot fail. Do not add it: a vacuous gate is
#    worse than a documented hole. alerts.yaml's header records the same
#    hole for the reader of the pack.
#    NULs become newlines first: BusyBox grep matches inside a
#    NUL-terminated line buffer, so a raw grep of the binary can miss a
#    literal that sits after a NUL on the same "line".
if [ -n "${KEEPALIVED_EXPECTED_VERSION:-}" ]; then
  for lit in \
    'VRRP_Script(%s) %s' \
    'timed_out' \
    'Entering FAULT STATE' \
    'entering FAULT state' \
    'leaving FAULT state' \
    'are both configured as address owner, please resolve' \
    'is still advertising as address owner, please resolve' \
    'equal priority advert received from remote host with our IP address' \
    'with lower priority %d, ours %d' \
    "Unknown keyword '" \
    'Line %zu)' \
    'Unable to read configuration file' \
    'Unable to find configuration file' \
    'Failed to open configuration file' \
    "Configuration file '" \
    '- disabling' \
    'Disabling track script' \
    'has no configuration to run' \
    'exited with permanent error' \
    'Non-existent interface specified in configuration' \
    'died: Respawning' \
    'Unable to lock process in memory'; do
    if ! tr '\0' '\n' </usr/sbin/keepalived | grep -qF -- "$lit"; then
      err "FAIL: alert matcher anchor missing from the shipped binary: $lit"
      err "      re-read alerts.yaml against the keepalived sources for this release"
      fail=1
    fi
  done
else
  log "note: KEEPALIVED_EXPECTED_VERSION unset - skipping alert-anchor check (local run)"
fi

[ "$fail" -eq 0 ] && log "keepalived smoke: ok"
exit "$fail"
