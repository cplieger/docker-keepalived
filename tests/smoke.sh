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

# iptables must remain absent. --disable-iptables is the whole gate (configure.ac
# tests enable_iptables before it probes for libiptc at all), so this fires only if
# autoconf stops recognising the flag and silently ignores it, which is the same
# detection the BFD assertion above provides.
if printf '%s\n' "$ver" | grep -qw IPTABLES; then
  err "FAIL: build gained IPTABLES support - the image ships nftables only"
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

# A stall makes max_auto_priority try to move the VRRP child to realtime, which
# fails here: a build step has no CAP_SYS_NICE. patches/ must leave exactly one
# "cannot raise priority". Unpatched keepalived also logs "Set realtime priority"
# and then a "cannot reset realtime scheduling" line from every script child.
if [ -n "${KEEPALIVED_EXPECTED_VERSION:-}" ] && [ -n "$iface" ]; then
  rt_dir=$(mktemp -d /root/smoke-rt.XXXXXX)
  trap 'rm -f "$conf" "$bad"; rm -rf "$exec_dir" "$rt_dir"' EXIT
  rt_conf="$rt_dir/vrrp.conf"
  rt_log="$rt_dir/keepalived.log"
  chmod 755 "$rt_dir"
  # Each run of the track script leaves one file, so runs can be counted.
  printf '%s\n' \
    'global_defs {' \
    '    enable_script_security' \
    '    script_user root' \
    '    max_auto_priority' \
    '    min_auto_priority_delay 500000' \
    '}' \
    'vrrp_script chk_rt {' \
    "    script \"/bin/mktemp $rt_dir/run.XXXXXX\"" \
    '    interval 1' \
    '}' \
    'vrrp_instance VI_RT {' \
    '    state BACKUP' \
    "    interface $iface" \
    '    virtual_router_id 254' \
    '    priority 100' \
    '    advert_int 1' \
    '    virtual_ipaddress {' \
    '        192.168.255.250/24' \
    '    }' \
    '    track_script {' \
    '        chk_rt' \
    '    }' \
    '}' >"$rt_conf"
  chmod 0644 "$rt_conf"
  rt_runs() {
    n=0
    for f in "$rt_dir"/run.*; do
      [ -e "$f" ] && n=$((n + 1))
    done
    printf '%s\n' "$n"
  }
  rt_wait_runs() {
    i=0
    while [ "$i" -lt 20 ]; do
      [ "$(rt_runs)" -ge "$1" ] && return 0
      i=$((i + 1))
      sleep 1
    done
    return 1
  }
  rt_count() { grep -cF -- "$1" "$rt_log" || true; }
  keepalived --dont-fork --log-console --log-detail -f "$rt_conf" >"$rt_log" 2>&1 &
  ka_pid=$!
  rt_ok=1
  if ! rt_wait_runs 1; then
    err "FAIL: the realtime check's track script never ran"
    rt_ok=0
  elif ! vrrp_pid=$(pgrep -P "$ka_pid") || [ -z "$vrrp_pid" ]; then
    err "FAIL: the realtime check found no VRRP child of keepalived"
    rt_ok=0
  else
    kill -STOP "$vrrp_pid"
    sleep 3
    kill -CONT "$vrrp_pid"
    runs_after_stall=$(rt_runs)
    if ! rt_wait_runs $((runs_after_stall + 5)); then
      err "FAIL: the track script did not run 5 more times after the stall"
      rt_ok=0
    fi
  fi
  kill "$ka_pid" 2>/dev/null || true
  wait "$ka_pid" 2>/dev/null || true
  if [ "$rt_ok" -eq 1 ]; then
    # Without the stall line the auto-priority path never ran and every count
    # below would hold for any binary.
    if [ "$(rt_count 'A thread timer expired')" -eq 0 ]; then
      err "FAIL: a 3s stop of the VRRP child was not reported as a late timer"
      rt_ok=0
    elif [ "$(rt_count 'cannot raise priority')" -ne 1 ] \
      || [ "$(rt_count 'Set realtime priority')" -ne 0 ] \
      || [ "$(rt_count 'cannot reset realtime scheduling')" -ne 0 ]; then
      err "FAIL: a failed realtime switch was not reported as exactly one 'cannot raise priority'"
      rt_ok=0
    fi
  fi
  if [ "$rt_ok" -eq 0 ]; then
    err "$(cat "$rt_log")"
    fail=1
  fi
else
  log "note: KEEPALIVED_EXPECTED_VERSION unset - skipping realtime fallback check (local run)"
fi

# keepalived runs a script line starting "</" through system(), and when a
# signal kills that shell the script child passes the signal on with
# kill(our_pid). Unpatched, our_pid still names the VRRP child, so SIGTERM stops
# it and the parent respawns it after every run. patches/ must keep the one VRRP
# child and log the script as failed by the signal.
if [ -n "${KEEPALIVED_EXPECTED_VERSION:-}" ] && [ -n "$iface" ]; then
  sig_dir=$(mktemp -d /root/smoke-sig.XXXXXX)
  trap 'rm -f "$conf" "$bad"; rm -rf "$exec_dir" "$rt_dir" "$sig_dir"' EXIT
  sig_conf="$sig_dir/vrrp.conf"
  sig_log="$sig_dir/keepalived.log"
  chmod 755 "$sig_dir"
  printf '%s\n' \
    'global_defs {' \
    '    enable_script_security' \
    '    script_user root' \
    '}' \
    'vrrp_script chk_sig {' \
    "    script \"'</dev/null;/bin/mktemp $sig_dir/run.XXXXXX;kill -TERM \$\$'\"" \
    '    interval 1' \
    '}' \
    'vrrp_instance VI_SIG {' \
    '    state BACKUP' \
    "    interface $iface" \
    '    virtual_router_id 252' \
    '    priority 100' \
    '    advert_int 1' \
    '    virtual_ipaddress {' \
    '        192.168.255.249/24' \
    '    }' \
    '    track_script {' \
    '        chk_sig' \
    '    }' \
    '}' >"$sig_conf"
  chmod 0644 "$sig_conf"
  sig_runs() {
    n=0
    for f in "$sig_dir"/run.*; do
      [ -e "$f" ] && n=$((n + 1))
    done
    printf '%s\n' "$n"
  }
  sig_count() { grep -cF -- "$1" "$sig_log" || true; }
  keepalived --dont-fork --log-console --log-detail -f "$sig_conf" >"$sig_log" 2>&1 &
  ka_pid=$!
  i=0
  while [ "$i" -lt 20 ] && [ "$(sig_runs)" -lt 3 ]; do
    i=$((i + 1))
    sleep 1
  done
  sig_n=$(sig_runs)
  sig_children=$(sig_count 'Starting VRRP child process')
  sig_failed=$(sig_count 'VRRP_Script(chk_sig) failed (due to signal 15)')
  kill "$ka_pid" 2>/dev/null || true
  wait "$ka_pid" 2>/dev/null || true
  if [ "$sig_n" -lt 3 ]; then
    err "FAIL: the signal check's track script ran $sig_n times, want 3"
    err "$(cat "$sig_log")"
    fail=1
  elif [ "$sig_children" -ne 1 ] || [ "$sig_failed" -eq 0 ]; then
    err "FAIL: a script shell killed by SIGTERM started $sig_children VRRP children, want 1, and was logged as failed by the signal $sig_failed times, want at least 1"
    err "$(cat "$sig_log")"
    fail=1
  fi
else
  log "note: KEEPALIVED_EXPECTED_VERSION unset - skipping script signal check (local run)"
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
    jq -e '.components[0].name == "keepalived"' "$sbom" >/dev/null || {
      err "FAIL: embedded SBOM fragment component is not named keepalived"
      fail=1
    }
    jq -e --arg want "$expected" '.components[0].version == $want' "$sbom" >/dev/null || {
      err "FAIL: embedded SBOM fragment version is not v${expected} (ARG wiring broken?)"
      fail=1
    }
    # Whole purl binds provenance to Dockerfile ARGs.
    want_patches=''
    for p in /tmp/patches/*.patch; do
      want_patches="${want_patches:+$want_patches,}${p##*/}"
    done
    purl="pkg:generic/keepalived@${expected}?download_url=https://www.keepalived.org/software/keepalived-${expected}.tar.gz&checksum=sha256:${KEEPALIVED_EXPECTED_SHA256:-}&patch=${want_patches}"
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
    'Unable to lock process in memory' \
    'Netlink: error: %s(%d), type=%s(%u), seq=%u, pid=%u' \
    'RTM_NEWADDR' \
    'RTM_DELADDR' \
    'RTM_NEWROUTE' \
    'RTM_DELROUTE' \
    'RTM_NEWRULE' \
    'RTM_DELRULE' \
    "Not adding address %s to %s since interface doesn't exist"; do
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
