#!/bin/sh
set -eu

# Verify wg-easy's WireGuard tunnel is functional by checking that
# UDP port 51820 is bound on the host. wg-easy publishes this port
# via Docker, so it appears in the host's UDP socket table. If
# wg-quick fails (e.g. nft hook errors), the port won't be bound.
# The web UI (port 51821) stays up even when wg0 fails to create,
# so checking that alone is unreliable.
#
# /proc/net/udp{,6} format: local_address (hex IP:port) — 51820 = 0xCA6C.
# Check both v4 and v6 tables, and anchor the match to the
# local_address column (column 2) so we never confuse a remote
# peer connection for our own listener.

# 51820 decimal = 0xCA6C (verify: printf '%04X\n' 51820).
# MUST match the WireGuard listen port in apps/wg-easy/compose.yaml
# (`51820:51820/udp` port mapping). If wg-easy's port is ever changed
# (e.g. to evade scanners), update this constant in the same commit
# or Keepalived will demote to BACKUP on healthy nodes and the VIP
# will flap. No shared source of truth today — full env-var plumbing
# is tracked in .review/TODO.md.
WG_PORT_HEX="CA6C"

# Both /proc/net/udp and /proc/net/udp6 unreadable is a distinct failure
# mode from "port not bound" — proc namespace hidden, LSM deny, kernel
# live patch mid-unmount — and should not masquerade as a wg-easy outage.
if [ ! -r /proc/net/udp ] && [ ! -r /proc/net/udp6 ]; then
  printf 'level=error msg="neither /proc/net/udp nor /proc/net/udp6 is readable"\n' >&2
  exit 1
fi

# FNR is the per-file line counter; NR would only skip the header of
# the first file and treat /proc/net/udp6's header as data. Harmless
# today (the header's column 2 is the literal "local_address") but
# the pattern is wrong under any future header change.
if ! awk -v port=":${WG_PORT_HEX}\$" '
        FNR == 1 { next }
        $2 ~ port { found = 1; exit }
        END { exit !found }
    ' /proc/net/udp /proc/net/udp6 2>/dev/null; then
  printf 'level=warn msg="wg-easy UDP port 51820 not bound (v4 or v6)"\n' >&2
  exit 1
fi
