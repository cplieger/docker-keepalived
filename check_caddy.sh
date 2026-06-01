#!/bin/sh
set -eu

# Verify Caddy is serving traffic by hitting its health endpoint on the
# host network. Keepalived tracks this check — failure triggers VRRP
# failover of the shared VIP to the backup node.
# Uses BusyBox wget (same tool Caddy's own healthcheck uses) to keep
# the two probes aligned and avoid a runtime curl dependency.
if ! wget -q --spider --timeout=5 http://127.0.0.1:80/health; then
  printf 'level=warn msg="caddy health check failed"\n' >&2
  exit 1
fi
