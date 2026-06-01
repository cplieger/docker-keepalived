#!/bin/sh
set -eu

# Verify Netbird's combined server is functional by checking that TCP port
# 33871 is bound on the host (mapped from container port 80, the
# 127.0.0.1:33871:80 in apps/netbird/compose.yaml). This mirrors
# check_wgeasy.sh: keepalived runs in the host network namespace so
# /proc/net/tcp shows host-bound ports.
#
# Why TCP-port-bound (and not /health endpoint): the /health endpoint may also
# probe Postgres connectivity. Postgres lives on Borgcube; if Borgcube dies,
# Defiant's /health would fail and chk_netbird in the VRRP track_script would
# also fail on Defiant, leaving NO MASTER for the VIP. By checking only the
# TCP listener, we detect "Netbird process crashed" (the case we want VIP
# failover for) without spuriously failing on a remote-DB outage that's
# already covered by the chk_caddy/chk_wgeasy track_scripts driving the VIP
# decision.
#
# /proc/net/tcp{,6} format: local_address (hex IP:port) - 33871 = 0x844F.
# We anchor the match on the local_address column (column 2) so we never
# confuse a remote peer connection for our own listener.

# 33871 decimal = 0x844F (verify: printf '%04X\n' 33871).
# MUST match the Netbird host port in apps/netbird/compose.yaml
# (`127.0.0.1:33871:80` port mapping). If that port is ever changed,
# update this constant in the same commit or Keepalived will demote
# to BACKUP on healthy nodes and the VIP will flap. Same single-source-
# of-truth caveat as check_wgeasy.sh; tracked in .review/TODO.md.
NETBIRD_PORT_HEX="844F"

# Both /proc/net/tcp and /proc/net/tcp6 unreadable is a distinct failure mode
# from "port not bound" - proc namespace hidden, LSM deny, kernel live patch
# mid-unmount - and should not masquerade as a Netbird outage.
if [ ! -r /proc/net/tcp ] && [ ! -r /proc/net/tcp6 ]; then
  printf 'level=error msg="neither /proc/net/tcp nor /proc/net/tcp6 is readable"\n' >&2
  exit 1
fi

# FNR is the per-file line counter; NR would only skip the header of the first
# file and treat /proc/net/tcp6's header as data.
if ! awk -v port=":${NETBIRD_PORT_HEX}\$" '
        FNR == 1 { next }
        $2 ~ port { found = 1; exit }
        END { exit !found }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
  printf 'level=warn msg="netbird-server TCP port 8081 not bound (v4 or v6)"\n' >&2
  exit 1
fi
