# docker-keepalived

Minimal Alpine-based container image for
[keepalived](https://www.keepalived.org/) (VRRP failover / high
availability), bundled with a set of health-check and notify helper
scripts (`check_*.sh`, `notify.sh`) installed to `/usr/local/bin`.

## Image

```
ghcr.io/cplieger/docker-keepalived
```

Multi-arch, signed (cosign) and SBOM-attested via the shared
[`cplieger/ci`](https://github.com/cplieger/ci) workflows.

## Usage

See [`compose.yaml`](./compose.yaml). Provide your `keepalived.conf` and run
with host networking + `NET_ADMIN`/`NET_RAW`.
