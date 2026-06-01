#!/bin/sh
set -eu

# Verify Netbird's standalone relay container is functional by checking that
# TCP port 33880 is bound on the host (mapped from container port 80, the
# 33880:80 in apps/netbird/compose.yaml's netbird-relay service). This mirrors
# check_netbird.sh: keepalived runs in the host network namespace so
# /proc/net/tcp shows host-bound ports.
#
# Why TCP-port-bound (and not /health endpoint): the /health endpoint may
# probe internal state we don't want gating VIP failover on. By checking only
# the TCP listener, we detect "Netbird relay process crashed" (the case we
# want VIP failover for). Same reasoning as check_netbird.sh - keep VRRP
# decisions local to the immediate process status.
#
# /proc/net/tcp{,6} format: local_address (hex IP:port) - 33880 = 0x8458.
# We anchor the match on the local_address column (column 2) so we never
# confuse a remote peer connection for our own listener.

# 33880 decimal = 0x8458 (verify: printf '%04X\n' 33880).
# MUST match the Netbird relay host port in apps/netbird/compose.yaml
# (`33880:80` port mapping on the netbird-relay service). If that port is
# ever changed, update this constant in the same commit or Keepalived will
# demote to BACKUP on healthy nodes and the VIP will flap. Same single-source-
# of-truth caveat as check_wgeasy.sh and check_netbird.sh.
NETBIRD_RELAY_PORT_HEX="8458"

# Both /proc/net/tcp and /proc/net/tcp6 unreadable is a distinct failure mode
# from "port not bound" - proc namespace hidden, LSM deny, kernel live patch
# mid-unmount - and should not masquerade as a Netbird relay outage.
if [ ! -r /proc/net/tcp ] && [ ! -r /proc/net/tcp6 ]; then
  printf 'level=error msg="neither /proc/net/tcp nor /proc/net/tcp6 is readable"\n' >&2
  exit 1
fi

# FNR is the per-file line counter; NR would only skip the header of the first
# file and treat /proc/net/tcp6's header as data.
if ! awk -v port=":${NETBIRD_RELAY_PORT_HEX}\$" '
        FNR == 1 { next }
        $2 ~ port { found = 1; exit }
        END { exit !found }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
  printf 'level=warn msg="netbird-relay TCP port 33880 not bound (v4 or v6)"\n' >&2
  exit 1
fi
