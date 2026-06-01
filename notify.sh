#!/bin/sh
# Keepalived notify script — observability only.
#
# Invoked by keepalived with: TYPE NAME STATE PRIORITY. Emits one structured
# log line per VRRP state transition so Loki/Grafana can alert on unexpected
# flips. radvd is managed by its own sibling container (not here) via
# `IgnoreIfMissing on` + `AdvRASrcAddress <VIP>` in radvd.conf; see
# https://fy.blackhats.net.au/blog/2018-11-01-high-available-radvd-on-linux/
# and radvd.conf(5).
#
# keepalived discards notify script stdio by default. Redirect both streams
# to PID 1's fds so docker logs captures them. PID 1 inside this container
# is keepalived (`--dont-fork`), whose stdio Docker captures.
# (See serverfault.com/q/759569 for why this is needed.)
# Guard the redirect: if /proc/1/fd/{1,2} is not writable (LSM policy, fd
# leak, future runtime change), fall back to the script's own stderr so
# transition logs are never silently lost. The warn line tells the operator
# why a transition log is missing from Loki.
if [ -w /proc/1/fd/1 ] && [ -w /proc/1/fd/2 ]; then
  exec >>/proc/1/fd/1 2>>/proc/1/fd/2
else
  printf 'level=warn msg="notify.sh could not redirect to PID 1 fds, logs may be lost"\n' >&2
fi

set -eu

if [ $# -lt 4 ]; then
  printf 'level=error msg="insufficient arguments" count=%d expected=4\n' "$#" >&2
  exit 1
fi

NAME="$2"
STATE="$3"
PRIORITY="${4:-}"

case "$NAME" in
  "")
    printf 'level=error msg="instance name is empty"\n' >&2
    exit 1
    ;;
  *[!a-zA-Z0-9._-]*)
    printf 'level=error msg="instance name contains invalid characters" name="%s"\n' "$NAME" >&2
    exit 1
    ;;
esac

case "$PRIORITY" in
  '' | *[!0-9]*)
    printf 'level=error msg="priority is empty or non-numeric" priority="%s" instance=%s\n' \
      "$PRIORITY" "$NAME" >&2
    exit 1
    ;;
esac

case "$STATE" in
  MASTER | BACKUP | STOP) level=info ;;
  FAULT) level=warn ;;
  *)
    printf 'level=error msg="unknown state" state="%s" instance=%s\n' "$STATE" "$NAME" >&2
    exit 1
    ;;
esac

printf 'level=%s msg="vrrp state transition" state=%s instance=%s priority=%s\n' \
  "$level" "$STATE" "$NAME" "$PRIORITY" >&2
