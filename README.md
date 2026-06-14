# docker-keepalived

[![CI](https://github.com/cplieger/docker-keepalived/actions/workflows/ci.yaml/badge.svg)](https://github.com/cplieger/docker-keepalived/actions/workflows/ci.yaml)
[![GitHub release](https://img.shields.io/github/v/release/cplieger/docker-keepalived)](https://github.com/cplieger/docker-keepalived/releases)
[![Image Size](https://ghcr-badge.egpl.dev/cplieger/docker-keepalived/size)](https://github.com/cplieger/docker-keepalived/pkgs/container/docker-keepalived)
![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)
![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/cplieger/docker-keepalived/badge)](https://scorecard.dev/viewer/?uri=github.com/cplieger/docker-keepalived)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/13205/badge)](https://www.bestpractices.dev/projects/13205)

Run [keepalived](https://www.keepalived.org/) (VRRP failover / high availability) in a container. Bring your own `keepalived.conf`.

## What it does

[keepalived](https://www.keepalived.org/) implements VRRP — the protocol that lets two or more machines share a virtual IP address with automatic failover. One node owns the VIP and serves traffic; if it dies, another node takes over within a few seconds. This is how active/passive high-availability typically works at the IP layer.

This image is a minimal Alpine wrapper around the upstream `keepalived` package. There's no entrypoint magic, no env-var-to-config translation, no bundled scripts: you mount your own `keepalived.conf` and any track / notify scripts it references, and keepalived runs as PID 1.

- **Multi-arch** — `linux/amd64` and `linux/arm64`
- **Tiny** — Alpine + the `keepalived` binary, nothing else
- **No bundled scripts** — bring your own track / notify helpers via the bind mount
- **Healthcheck** — built-in `pidof keepalived` process check

### Why this design

- **Generic upstream-only** — no custom track scripts baked in. The image is reusable across any VRRP topology without inheriting someone else's check logic
- **Bind-mount only** — single read-only `:ro` mount of `/etc/keepalived` keeps the container's writable surface zero
- **Host networking** — VRRP uses multicast (224.0.0.18 for IPv4, ff02::12 for IPv6) and needs the host's network namespace to advertise on a real LAN interface
- **No PID 1 wrapper** — `keepalived --dont-fork` runs as PID 1 directly, so SIGTERM from `docker stop` reaches it instantly without a wrapper layer

## Quick start

Available from both `ghcr.io/cplieger/docker-keepalived` and `docker.io/cplieger/docker-keepalived` — identical images and tags.

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

    # Mount your keepalived.conf — and any track / notify scripts it
    # references. A scripts/ subdir alongside keepalived.conf is the
    # natural layout, with paths like /etc/keepalived/scripts/<name>.sh.
    volumes:
      - ./keepalived:/etc/keepalived:ro
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
        192.168.1.250/24
    }
    track_script {
        chk_app
    }
}
```

The backup node uses the same config with `state BACKUP`, `priority 100`, and the same `auth_pass`.

## ⚠️ enable_script_security and bind-mount permissions

If your `keepalived.conf` sets `enable_script_security` in `global_defs` (recommended), keepalived **refuses to execute scripts whose path inside the container has any non-root-writable component**. Track scripts get silently disabled with this log line:

```text
Unsafe permissions found for script '/etc/keepalived/scripts/check_app.sh' - disabling.
Disabling track script chk_app due to insecure
```

Inside the container, `/etc/keepalived` mirrors the host bind-mount source's ownership and mode. So you need to ensure:

- The host directory you mount at `/etc/keepalived` is owned by `root:root`
- The directory is **not group-writable or world-writable** (mode 755 is fine; 770 is not because group-writable counts as "writable by non-root")
- Same for any `scripts/` subdirectory — must be `root:root` and not group-writable

A common gotcha: many homelab path conventions (`/srv/containers/<app>/`, `/mnt/applications/containers/<app>/`) inherit non-root ownership from a parent dir. Fix on each server with:

```bash
chown -R root:root /path/to/keepalived
chmod 755 /path/to/keepalived /path/to/keepalived/scripts
```

If you don't use `enable_script_security`, none of this applies — but you should use it.

## Configuration reference

### Volumes

| Mount | Description |
|-------|-------------|
| `/etc/keepalived` | Your `keepalived.conf` and any track / notify scripts it references. Mount read-only. **Must be root-owned and not group/world-writable** if `enable_script_security` is set. |

### Capabilities

| Capability | Why needed |
|------------|-----------|
| `NET_ADMIN` | Adding / removing the virtual IP, socket option configuration |
| `NET_RAW` | Constructing VRRP packets (raw sockets) and ICMP probes |

### Networking

| Setting | Value | Reason |
|---------|-------|--------|
| `network_mode` | `host` | VRRP advertisements use multicast on the LAN segment; container networking would isolate them |

VRRP multicast addresses (RFC 5798): `224.0.0.18` (IPv4), `ff02::12` (IPv6). `NET_BROADCAST` is **not** required.

## Healthcheck

The built-in healthcheck verifies the keepalived process is running:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof keepalived >/dev/null || exit 1
```

This catches the "process crashed" failure mode but not "VRRP is stuck": for that, watch the `notify` script logs and the VRRP_Script success/failure log lines, or scrape keepalived's stats interface (`SIGUSR2` triggers a stats dump to `/tmp/keepalived.stats`).

## Reload without restart

To apply a config change without a container restart (no VIP transition):

```bash
docker kill -s HUP keepalived
```

keepalived re-reads `keepalived.conf` and applies any changes — track scripts are re-evaluated, instance config is reapplied. VRRP state is preserved for unchanged instances; only changed instances briefly renegotiate.

## Security

| Tool | Result |
|------|--------|
| [hadolint](https://github.com/hadolint/hadolint) | Clean |
| [gitleaks](https://github.com/gitleaks/gitleaks) | No secrets detected |
| [trivy](https://trivy.dev/) | Inherits the Alpine base image scan |

The image is published with [cosign](https://github.com/sigstore/cosign) signatures and SBOM attestations. Verify a pull:

```bash
cosign verify ghcr.io/cplieger/docker-keepalived:latest \
    --certificate-identity-regexp "https://github.com/cplieger/docker-keepalived/.github/workflows/.*" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Pairing with radvd for IPv6 HA

If you advertise IPv6 prefixes on the LAN with radvd, keepalived can manage the IPv6 VIP and radvd can use it as the source address for Router Advertisements via `AdvRASrcAddress`. See [docker-radvd](https://github.com/cplieger/docker-radvd) for a sibling container that's already wired up for this pattern.

## Dependencies

Dependencies are updated automatically via [Renovate](https://github.com/renovatebot/renovate). The base image is pinned by SHA digest; the `keepalived` apk package is installed unpinned so it tracks the digest-pinned base (pinning the apk revision strands the build when Alpine bumps releases and drops the old revision):

- **Alpine Linux** — base image ([Docker Hub](https://hub.docker.com/_/alpine))
- **keepalived** — Alpine community package ([upstream](https://www.keepalived.org/))

## Credits

This project packages [keepalived](https://github.com/acassen/keepalived) into a container image. All credit for the core functionality goes to the upstream maintainers — Alexandre Cassen and the keepalived community.

## Contributing

Issues and pull requests are welcome. Please open an issue first for larger changes so the approach can be discussed before implementation.

## Disclaimer

This image is built with care and follows security best practices, but it is intended for **homelab use**. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude Opus](https://www.anthropic.com/claude) and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
