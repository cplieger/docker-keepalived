#!/usr/bin/env bash
# The example virtual IP probe rule in docs/monitoring.md is checked here, because
# the alert rule checks read only the files under alerts/.
# PROMTOOL names a local promtool binary; without it the pinned image runs promtool.
#
# SC2015: `cond && ok || no` cannot mis-fire, because lib.sh's ok/no return 0.
# shellcheck disable=SC2015
set -u

# shellcheck source-path=SCRIPTDIR
. "$(dirname -- "$0")/lib.sh"
new_workdir >/dev/null

page=$REPO_ROOT/docs/monitoring.md
image=prom/prometheus:v3.16.0@sha256:e04987641b57704f408e31f6373ba4138ecf27cb4a165d24aabb6c38fddd0f06
rule=$WORK/probe.yaml

# The image runs promtool as an unprivileged user, which must read the rule file.
chmod 755 "$WORK"
awk '
  /^## / { in_section = ($0 == "## Knowing the app is alive"); next }
  in_section && !done && /^```yaml$/ { in_block = 1; next }
  in_block && /^```$/ { in_block = 0; done = 1; next }
  in_block { print }
' "$page" >"$rule"
chmod 644 "$rule"

if [ ! -s "$rule" ]; then
  no "example rule extraction" "docs/monitoring.md has no yaml block under \"## Knowing the app is alive\""
  report
  exit
fi
ok "docs/monitoring.md shows a yaml example under Knowing the app is alive"

grep -q 'probe_success{job="[^"]*"} == 0' "$rule" \
  && ok "the example rule fires on a failed probe, with an exact job matcher" \
  || no "failed-probe arm" "no probe_success{job=\"...\"} == 0 in the example rule"
grep -q 'absent(probe_success{job="[^"]*"})' "$rule" \
  && ok "the example rule fires when the probe stops reporting" \
  || no "absent arm" "no absent(probe_success{job=\"...\"}) in the example rule"

if [ -n "${PROMTOOL:-}" ]; then
  "$PROMTOOL" check rules "$rule" >"$WORK/promtool.out" 2>&1
  rc=$?
elif command -v docker >/dev/null 2>&1; then
  # Three pulls, so one registry timeout on a shared runner does not fail the rule check.
  for attempt in 1 2 3; do
    docker pull -q "$image" >/dev/null && break
    sleep $((attempt * 5))
  done
  docker run --rm --network none --entrypoint promtool -v "$WORK:/rules:ro" "$image" \
    check rules /rules/probe.yaml >"$WORK/promtool.out" 2>&1
  rc=$?
else
  printf 'set PROMTOOL to a promtool binary, or install Docker to run %s\n' "$image" >"$WORK/promtool.out"
  rc=127
fi
[ "$rc" -eq 0 ] \
  && ok "promtool check rules accepts the example rule" \
  || no "promtool check rules" "rc=$rc: $(cat "$WORK/promtool.out")"

report
