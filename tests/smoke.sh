#!/bin/sh
set -eu

d=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
fail=0
log() { printf '%s\n' "$*"; }
err() { printf '%s\n' "$*" >&2; }

if ! ver=$(keepalived --version 2>&1); then
  err "FAIL: 'keepalived --version' did not run"
  err "$ver"
  fail=1
fi

# Dockerfile sets this in the image; local runs skip it.
if [ -n "${KEEPALIVED_EXPECTED_VERSION:-}" ]; then
  expected=${KEEPALIVED_EXPECTED_VERSION#v}
  if ! printf '%s\n' "$ver" | head -n 1 | grep -qF "Keepalived v${expected} ("; then
    err "FAIL: version mismatch: expected v${expected}, got: $(printf '%s\n' "$ver" | head -n 1)"
    fail=1
  fi
else
  log "note: KEEPALIVED_EXPECTED_VERSION unset - skipping exact-version check (local run)"
fi

# Keep Alpine's NFTABLES and JSON feature parity.
for feat in NFTABLES JSON; do
  if ! printf '%s\n' "$ver" | grep -qw "$feat"; then
    err "FAIL: keepalived built without $feat support (parity floor)"
    fail=1
  fi
done

# BFD must remain absent; alerts/logql.yaml and README.md exclude it.
if printf '%s\n' "$ver" | grep -qw BFD; then
  err "FAIL: build gained BFD support — alerts/logql.yaml and README.md name no BFD directive"
  fail=1
fi

# Dockerfile gate covers image-only genhash dispatch.
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

# chmod prevents keepalived -t from silently skipping an executable config.
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

# A rejected config proves -t parsed it; skipped configs exit zero.
grep -v 'script_user root' "$d/keepalived.conf" >"$bad"
chmod 0644 "$bad"
if bad_out=$(keepalived -t -f "$bad" --log-console --log-detail 2>&1); then
  err "FAIL: 'keepalived -t' accepted a config it should reject (vacuous gate?)"
  err "$bad_out"
  fail=1
fi

# A script keepalived cannot execute must be reported. keepalived reports that
# from a child whose stderr it has already redirected to /dev/null, so under the
# entrypoint's --dont-fork --log-console the report reaches nothing and a broken
# track or notify hook has no symptom at all; patches/ keeps a copy of the
# console for it. A track script drives the failure because it runs as soon as
# the VRRP child does, needing neither an election nor NET_ADMIN. -t cannot
# stand in: it exits 0 on a notify script that does not exist.
if [ -n "${KEEPALIVED_EXPECTED_VERSION:-}" ]; then
  iface=
  for n in /sys/class/net/*; do
    case ${n##*/} in
      lo | '*') continue ;;
    esac
    iface=${n##*/}
    break
  done
  exec_dir=$(mktemp -d /root/smoke-exec.XXXXXX)
  trap 'rm -f "$conf" "$bad"; rm -rf "$exec_dir"' EXIT
  exec_script="$exec_dir/hook.sh"
  exec_conf="$exec_dir/vrrp.conf"
  exec_log="$exec_dir/keepalived.log"
  if [ -z "$iface" ]; then
    err "FAIL: no non-loopback interface, so no VRRP instance can start here"
    fail=1
  else
    # A shebang naming an interpreter the image does not ship passes every
    # check keepalived makes before the fork and fails at execve. The other
    # real shape is a noexec mount, which a build stage cannot create.
    printf '#!/nonexistent/interpreter\n' >"$exec_script"
    chmod 755 "$exec_dir" "$exec_script"
    printf '%s\n' \
      'global_defs {' \
      '    enable_script_security' \
      '    script_user root' \
      '}' \
      'vrrp_script chk_exec {' \
      "    script \"$exec_script\"" \
      '    interval 1' \
      '    fall 1' \
      '    rise 1' \
      '}' \
      'vrrp_instance VI_EXEC {' \
      '    state BACKUP' \
      "    interface $iface" \
      '    virtual_router_id 253' \
      '    priority 100' \
      '    advert_int 1' \
      '    virtual_ipaddress {' \
      '        192.168.255.252/24' \
      '    }' \
      '    track_script {' \
      '        chk_exec' \
      '    }' \
      '}' >"$exec_conf"
    chmod 0644 "$exec_conf"
    keepalived --dont-fork --log-console --log-detail -f "$exec_conf" >"$exec_log" 2>&1 &
    ka_pid=$!
    # The same three matchers alerts/logql.yaml keys on, bound to this script's
    # own path so an unrelated line cannot satisfy the assertion.
    exec_re="(Error exec-ing command|Couldn't (find|execute) command).*$exec_script"
    i=0
    while [ "$i" -lt 20 ]; do
      if grep -Eq -- "$exec_re" "$exec_log"; then break; fi
      i=$((i + 1))
      sleep 1
    done
    kill "$ka_pid" 2>/dev/null || true
    wait "$ka_pid" 2>/dev/null || true
    if ! grep -Eq -- "$exec_re" "$exec_log"; then
      err "FAIL: keepalived reported nothing about a track script it could not execute"
      err "$(cat "$exec_log")"
      fail=1
    fi
  fi
else
  log "note: KEEPALIVED_EXPECTED_VERSION unset - skipping script-exec report check (local run)"
fi

if [ -n "${KEEPALIVED_EXPECTED_VERSION:-}" ]; then
  sbom=/usr/share/sbom/keepalived.cdx.json
  expected=${KEEPALIVED_EXPECTED_VERSION#v}
  if [ ! -s "$sbom" ]; then
    err "FAIL: embedded SBOM fragment missing or empty: $sbom"
    fail=1
  else
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
    # Whole purl binds provenance to Dockerfile ARGs.
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

# Alert anchors must occur in the binary; version bumps do not re-evaluate alerts.
# `failed` cannot be anchored because unrelated binary strings can satisfy it.
# Split NULs because BusyBox grep can miss later bytes on the same line.
if [ -n "${KEEPALIVED_EXPECTED_VERSION:-}" ]; then
  for lit in \
    'VRRP_Script(%s) %s' \
    'timed_out' \
    'succeeded' \
    'Entering FAULT STATE' \
    'entering FAULT state' \
    'Entering BACKUP STATE' \
    'Entering MASTER STATE' \
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
    "Error exec-ing command '" \
    "Couldn't find command: " \
    "Couldn't execute command: " \
    'Wrong file type found in script path' \
    'cannot be accessed - ' \
    'specify unicast peers' \
    'at a reload - please restart' \
    'auth_hmac active_key' \
    'invalid passwd from' \
    'Invalid auth type from' \
    'auth from %s, expecting' \
    'wrong VRRP version from' \
    'advertisement interval mismatch with' \
    'icast packet but received' \
    'authentication trailer from' \
    'invalid authentication HMAC from' \
    'unknown authentication key id' \
    'not a unicast peer' \
    'invalid TTL/HL from' \
    'TTL/HL %d from' \
    'has no configuration to run' \
    'exited with permanent error' \
    'Non-existent interface specified in configuration' \
    'died: Respawning' \
    'Unable to lock process in memory'; do
    if ! tr '\0' '\n' </usr/sbin/keepalived | grep -qF -- "$lit"; then
      err "FAIL: alert matcher anchor missing from the shipped binary: $lit"
      err "      re-read alerts/logql.yaml against the keepalived sources for this release"
      fail=1
    fi
  done
else
  log "note: KEEPALIVED_EXPECTED_VERSION unset - skipping alert-anchor check (local run)"
fi

[ "$fail" -eq 0 ] && log "keepalived smoke: ok"
exit "$fail"
