# docker-keepalived

Minimal Alpine-based container image for
[keepalived](https://www.keepalived.org/) (VRRP failover / high
availability). Single static binary on top of Alpine — bring your own
`keepalived.conf` (and any track / notify scripts it references) via a
read-only bind mount.

## Image

```
ghcr.io/cplieger/docker-keepalived
```

Multi-arch, signed (cosign) and SBOM-attested via the shared
[`cplieger/ci`](https://github.com/cplieger/ci) workflows.

## Usage

See [`compose.yaml`](./compose.yaml). Provide your `keepalived.conf` and run
with host networking + `NET_ADMIN`/`NET_RAW`.

If your config uses `enable_script_security`, the bind-mount source must
be root-owned and not group/world-writable — otherwise track scripts
will be disabled at reload. The reference compose includes a comment on
this.
