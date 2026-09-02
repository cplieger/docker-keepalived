# docker-keepalived

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-keepalived/badges/size.json)](https://github.com/cplieger/docker-keepalived/pkgs/container/docker-keepalived)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13205/badge)](https://www.bestpractices.dev/projects/13205)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-keepalived/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-keepalived)
[![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-keepalived/releases)

<!-- hub-overview BEGIN -->
Run [keepalived](https://www.keepalived.org/) (VRRP failover / high availability) in a container. Bring your own `keepalived.conf`.

## What it does

[keepalived](https://www.keepalived.org/) implements VRRP, so two or more machines share a virtual IP with automatic failover: one node owns the VIP, and another takes over within seconds if it dies.

This image is a minimal Alpine wrapper around upstream `keepalived`, compiled from a pinned upstream source release. There's no entrypoint magic, no env-var-to-config translation, no bundled scripts: you mount your own `keepalived.conf` and any track / notify scripts it references, and keepalived runs as PID 1. The image also ships keepalived's `genhash` digest helper for `HTTP_GET` checker configuration.

### Why this design

- **Generic upstream-only**: no custom track scripts baked in, so the image works for any VRRP topology without inheriting someone else's check logic
- **Bind-mount only**: all configuration arrives through one read-only `:ro` mount of `/etc/keepalived`, and the published example adds no writable bind mounts
- **No PID 1 wrapper**: `keepalived --dont-fork` runs as PID 1 directly, so SIGTERM from `docker stop` reaches it instantly
<!-- hub-overview END -->

## Quick start

Available from both `ghcr.io/cplieger/docker-keepalived` and `docker.io/cplieger/docker-keepalived`: identical images and tags.

```yaml
services:
  keepalived:
    image: ghcr.io/cplieger/docker-keepalived:latest
    container_name: keepalived
    restart: unless-stopped

    # VRRP needs host networking + raw socket / admin caps.
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW

    # Mount your keepalived.conf and any track / notify scripts it references.
    # A scripts/ subdir alongside keepalived.conf is the natural layout, with
    # paths like /etc/keepalived/scripts/<name>.sh.
    volumes:
      - "./keepalived:/etc/keepalived:ro"
```

Minimal `keepalived.conf` (active node, priority 150):

```conf
global_defs {
    router_id MY_PRIMARY
    script_user root
    enable_script_security
}

vrrp_script chk_app {
    script "/etc/keepalived/scripts/check_app.sh"
    interval 5
    timeout 3
    fall 2
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 150
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass changeme
    }
    virtual_ipaddress {
        192.0.2.250/24
    }
    track_script {
        chk_app
    }
}
```

The backup node uses the same config with `state BACKUP`, `priority 100`, and the same `auth_pass`.

## ⚠️ enable_script_security and bind-mount permissions

If your `keepalived.conf` sets `enable_script_security` in `global_defs` (recommended), keepalived **refuses to execute scripts whose path inside the container has any non-root-writable component**. It disables the track script and names it in the log:

```text
Unsafe permissions found for script '/etc/keepalived/scripts/check_app.sh' - disabling.
Disabling track script chk_app due to insecure
```

Inside the container, `/etc/keepalived` mirrors the host bind-mount source's ownership and mode. So you need to ensure:

- The host directory you mount at `/etc/keepalived`, and any `scripts/` subdirectory, is owned by `root:root` and **not group- or world-writable** (mode 755 is fine; 770 is not, because group-writable counts as "writable by non-root")
- Each track / notify script **file** must also be root-owned and not group/world-writable; keepalived applies the same check to the script file, not just its parent directories

Watch for host directories that inherit non-root ownership from a parent directory. Fix on each server with:

```bash
chown -R root:root /path/to/keepalived
chmod 755 /path/to/keepalived /path/to/keepalived/scripts
# script files must also be non-group/world-writable (keepalived checks the file too)
chmod 644 /path/to/keepalived/keepalived.conf
find /path/to/keepalived/scripts -type f -exec chmod 755 {} +
```

If you don't use `enable_script_security`, the script-permission rules above do not apply, but you should use it. One check applies either way: keepalived will not use a config file that is not a regular file or has an execute bit set (`Configuration file '...' is not a regular non-executable file - skipping`). For your mounted `keepalived.conf`, that is fatal at startup: keepalived exits before starting VRRP and the restart policy crash-loops the container. `KeepalivedPermanentError` stays silent because no child process died. Keep `keepalived.conf` mode 644, whatever else you set. The same line means the daemon carried on when the skipped file was an `include`d one rather than the main config.

## Configuration reference

### Volumes

| Mount             | Description                                                                                                                                                                   |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `/etc/keepalived` | Your `keepalived.conf` and any track / notify scripts it references. Mount read-only. **Must be root-owned and not group/world-writable** if `enable_script_security` is set. |

### Capabilities

| Capability  | Why needed                                                    |
| ----------- | ------------------------------------------------------------- |
| `NET_ADMIN` | Adding / removing the virtual IP, socket option configuration |
| `NET_RAW`   | Constructing VRRP packets (raw sockets) and ICMP probes       |

### Networking

| Setting        | Value  | Reason                                                                                        |
| -------------- | ------ | --------------------------------------------------------------------------------------------- |
| `network_mode` | `host` | VRRP advertisements use multicast on the LAN segment; container networking would isolate them |

VRRP multicast addresses (RFC 5798): `224.0.0.18` (IPv4), `ff02::12` (IPv6). `NET_BROADCAST` is **not** required.

### Resource limits

The image needs no resource limits to run, with one exception. If your `keepalived.conf` sets `vrrp_no_swap` (or `checker_no_swap`), raise the container's locked-memory limit too, or the option will not do what it says.

Those options make the child process call `mlockall()`, and `RLIMIT_MEMLOCK` is charged against locked _address space_, not resident memory. A container that sets no `ulimits:` inherits the Docker daemon's own limit, which on a systemd host is 8 MiB unless the daemon's unit says otherwise. This image's VRRP child maps about 7.4 MiB of program text and shared libraries before its first allocation (OpenSSL's libcrypto is 4.8 MiB of that, amd64), so 8 MiB leaves it almost no room — and 64 KiB, the kernel default on hosts with no systemd bump, leaves it none at all.

```yaml
    ulimits:
      memlock:
        soft: 67108864  # 64 MiB, ~8x the child's mapped size
        hard: 67108864
```

Two failure modes, so you can tell them apart in `docker logs`:

- **Limit below the child's virtual size.** `mlockall` fails at startup, keepalived logs `Unable to lock process in memory - Cannot allocate memory` once, and carries on with `vrrp_no_swap` silently inert from then on. The `KeepalivedMemlockFailed` rule in [`alerts/logql.yaml`](alerts/logql.yaml) is what catches it (see [Alerting](#alerting)).
- **Limit just above it.** The lock succeeds and a later allocation is refused instead: `Keepalived: Resource temporarily unavailable` (no timestamp — it is a `perror`, not a log line), the VRRP child exits 204, and the parent respawns it, which moves the VIP out and back. The `pidof` healthcheck stays green, because the parent is what survives; the `KeepalivedChildRespawned` rule in [`alerts/logql.yaml`](alerts/logql.yaml) is what catches it (see [Alerting](#alerting)). keepalived prints `Please log an issue at ...` for any child death, so that banner is not evidence of an upstream bug.

Check what your host actually granted:

```bash
docker exec keepalived grep 'Max locked memory' /proc/1/limits
```

Sizing caveat: keepalived's interface table gains an entry per interface the host has ever had and does not release it ([upstream #2709](https://github.com/acassen/keepalived/issues/2709)), and every container start on the host creates a veth. So on a busy host a finite limit sets how long the child lives rather than preventing the exit — headroom buys time, it is not a cure.

## Healthcheck

The built-in healthcheck runs `pidof keepalived` every 30s (5s timeout, 3 retries, 15s start period). It catches a crashed process but not a stuck VRRP. The image runs `keepalived --dont-fork --log-console --log-detail`, so every VRRP state transition, track-script success/failure line, and the `Unsafe permissions found ... - disabling` warning lands in `docker logs keepalived` (and any log shipper scraping it); watch there for what the `pidof` probe cannot see.

Three signals write a dump under `/tmp`, and the state is in two of them. `SIGUSR1` writes `keepalived.data`, with a `State = MASTER|BACKUP|FAULT` line for each instance. `SIGRTMIN+2` writes `keepalived.json`, with `state` and `wantstate` as numbers. `SIGUSR2` writes `keepalived.stats`, which holds counters only (adverts, master transitions, packet and authentication errors) and no state field. `SIGRTMIN` depends on the C library, and in this image it is 35, so the JSON dump is `docker kill -s 37 keepalived`. Read a dump with `docker exec keepalived cat /tmp/keepalived.data`.

## Alerting

keepalived logs VRRP state transitions and config events to its container log (the same stream the [Healthcheck](#healthcheck) section describes shipping to a log collector). Ship it to Loki and evaluate the rules in [`alerts/logql.yaml`](alerts/logql.yaml) with Loki's ruler; firing alerts deliver through your Alertmanager like any Prometheus alert. They cover:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `KeepalivedTrackScriptFailed` | a VRRP track script reports failed or times out (failover imminent) | critical |
| `KeepalivedFaultState` | a VRRP instance enters FAULT state and drops out of the election | critical |
| `KeepalivedDuplicateMaster` | two nodes claim the same VRRP address: an address-owner conflict, an advert carrying this node's own IP, repeated lower-priority adverts, or a peer whose adverts this node rejects outright (an auth password mismatch, an auth type mismatch where neither side is AH, a wrong VRRP version, a VRRPv2 advert-interval mismatch, unicast adverts on a multicast instance or vice versa, a missing or invalid authentication extension, an address outside the `unicast_peer` list, or a TTL or hop-limit failure) | critical |
| `KeepalivedConfigError` | keepalived logged a config error and kept running with it: an unknown keyword, a `(Line N)`-prefixed parse error, an instance disabled by a config fault, a config that declared nothing to run, an `auth_hmac` `active_key` that names no defined key, so the instance runs unauthenticated, or a reload it refused outright so none of your edits applied. A config file it could not open, read, find, or use as a regular non-executable file has the opposite meaning at container start: keepalived exits and the container crash-loops | warning |
| `KeepalivedScriptDisabled` | keepalived refused to run a track or notify script and disabled it: a refused track script means this node never fails over on that check; a refused notify script means the side effect of a state change never runs. The container stays healthy in both cases | critical |
| `KeepalivedPermanentError` | a keepalived child ends with a permanent error (a missing interface, a duplicate `virtual_router_id`) and the parent terminates, so the container crash-loops | critical |
| `KeepalivedChildRespawned` | a keepalived child process died and was respawned (the log line names which child) | warning |
| `KeepalivedMemlockFailed` | `mlockall` failed, so `vrrp_no_swap` is inert and the VRRP child can be swapped out | warning |

Thresholds and the `severity` labels are starting points; adjust the container and label selectors (such as the `hostname` grouping) to match your log collector, and route by whatever labels your Alertmanager uses.

These rules read what keepalived reports about itself, and a completed takeover is in that report. The node that stops logs `(NAME) sent 0 priority`. The survivor logs `(NAME) Backup received priority 0 advertisement` before `Entering MASTER STATE`. A master that loses an election while alive logs `Master received advert from <peer> with higher priority P, ours Q`, or `... with same priority P but higher IP address than ours`. The image passes `--log-detail`, which the two priority-0 lines need, so every line above is in `docker logs keepalived` already.

Only a node that dies outright is silent. The survivor then logs `Entering MASTER STATE` and nothing else, which every boot election logs too, so a rule for that case has to know which node should hold the VIP. That decision is yours, and the rule belongs in your own rule set alongside these.

## Reload without restart

To apply a config change without a container restart (no VIP transition):

```bash
docker kill -s HUP keepalived
```

keepalived re-reads `keepalived.conf` and applies any changes. VRRP state is preserved for unchanged instances, and only changed instances briefly renegotiate. Seven settings cannot be changed this way: the top-level `net_namespace`, `net_namespace_ipvs` and `instance`, and the `global_defs` entries `nftables`, `nftables_ipvs`, `tmp_config_directory` and `disable_local_igmp`. keepalived logs `Cannot change ... at a reload - please restart keepalived`; it names its own internal field rather than the directive, so the log text and the spelling you wrote will differ. It then keeps the old configuration and never signals its VRRP child, so every other edit in the file is discarded too. That needs a `docker restart`, and the `KeepalivedConfigError` rule in [`alerts/logql.yaml`](alerts/logql.yaml) catches it.

## Security

The container runs as root by design: keepalived adds and removes the VIP on a host interface (`NET_ADMIN`) and constructs raw VRRP packets (`NET_RAW`). Grant those two capabilities with `cap_add` rather than `privileged`, and mount `/etc/keepalived` read-only. That mount is the only bind mount the image needs. One scan finding is accepted: the "image user should not be root" misconfiguration check (AVD-DS-0002), because a non-root user cannot manage the VIP. Current scan results live in the repository's Security tab.

The container root filesystem stays writable, so `read_only: true` is not free. At startup keepalived creates its own pidfile and its VRRP child's pidfile under `/run`. If it cannot create a pidfile, it treats the failure as proof that a second instance runs: on a read-only root it logs `daemon is already running` and exits, and that message names the wrong cause. A tmpfs at `/run` is all the hardened profile needs:

```yaml
    read_only: true
    tmpfs:
      - /run:size=1m
```

`/tmp` is a separate question. The three signal dumps write there (see [Healthcheck](#healthcheck)). On a read-only root a dump logs that it cannot open its file, such as `Can't open /tmp/keepalived.stats`, and keepalived continues. Add a second tmpfs at `/tmp` only if you use the dumps.

The image is published with [cosign](https://github.com/sigstore/cosign) signatures and SBOM attestations. Verify a pull:

```bash
cosign verify ghcr.io/cplieger/docker-keepalived:latest \
    --certificate-identity-regexp "https://github.com/cplieger/docker-keepalived/.github/workflows/.*" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Pairing with radvd for IPv6 HA

If you advertise IPv6 prefixes on the LAN with radvd, keepalived can manage the IPv6 VIP and radvd can use it as the source address for Router Advertisements via `AdvRASrcAddress`. See [docker-radvd](https://github.com/cplieger/docker-radvd) for a sibling container that's already wired up for this pattern.

## Dependencies

Dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate). The base image is pinned by SHA digest; keepalived itself is built from a pinned upstream source release whose tarball is SHA256-verified at build time, so a hash mismatch fails the build:

- **Alpine Linux**: base image ([Docker Hub](https://hub.docker.com/_/alpine))
- **keepalived**: built from the pinned upstream source tarball ([upstream](https://www.keepalived.org/)), with feature parity to Alpine's packaged build (nftables, libnl3, OpenSSL, JSON; no SNMP, no systemd)

A new upstream keepalived release triggers a version bump, rebuild, and republish. The Alpine runtime libraries keepalived links against (libnl3, libnftnl, libmnl, OpenSSL) float forward at image build time, and published images are rebuilt automatically once the last successful build exceeds a staleness interval. Operators who need a faster patch response can rebuild or pull on their own cadence, or run a [trivy](https://trivy.dev/) scan of the `:latest` image.

### Migration note: source build (major version)

Earlier image versions installed keepalived from the Alpine community repository (keepalived 2.3.4 on Alpine 3.24). The image now compiles the daemon from the pinned upstream release, which moves it to the current upstream line (2.4.x at the time of this change). The container interface is unchanged: same `/etc/keepalived` read-only bind mount, same capabilities (`NET_ADMIN`, `NET_RAW`), same signals (`HUP` config reload, `USR2` stats dump), same `pidof` healthcheck, and the same `keepalived --dont-fork --log-console --log-detail` PID 1 entrypoint. Review the [upstream changelog](https://github.com/acassen/keepalived/blob/master/ChangeLog) for keepalived 2.4.x behavior changes before rolling it out across an HA pair.

## Credits

This project packages [keepalived](https://github.com/acassen/keepalived) (GPL-2.0) into a container image. All credit for the core functionality goes to the upstream maintainers, Alexandre Cassen and the keepalived community.

## Contributing

Issues and pull requests are welcome. Please open an issue first for larger changes so the approach can be discussed before implementation.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude](https://claude.com), [GPT](https://openai.com), and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

Apache-2.0. See [LICENSE](LICENSE).
