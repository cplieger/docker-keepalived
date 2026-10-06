# Security

This page covers the privilege model, a read-only root filesystem, the patch in the keepalived binary, image signatures and what the image contains. It is for operators who harden or audit a deployment.

## Privilege model

The container runs as root by design. keepalived needs `NET_ADMIN` to add and remove the virtual IP on a host interface and `NET_RAW` to build raw VRRP packets. Grant those two capabilities with `cap_add` rather than `privileged`, and mount `/etc/keepalived` read-only. That mount is the only bind mount the image needs.

One scan finding is accepted, the "image user should not be root" check (AVD-DS-0002), because a non-root user cannot manage the virtual IP. Current scan results are in the repository's Security tab.

## Read-only root filesystem

The container root filesystem is writable by default, and `read_only: true` needs one addition. At startup keepalived creates its own pidfile and its VRRP child's pidfile under `/run`. When it cannot create a pidfile, it treats that as proof that a second instance runs. On a read-only root it logs `daemon is already running` and exits, and that message names the wrong cause. A tmpfs at `/run` is all a read-only profile needs:

```yaml
    read_only: true
    tmpfs:
      - /run:size=1m
```

`/tmp` is a separate question. The three state dumps write there, as [Monitoring and alerts](monitoring.md#reading-the-current-state) describes. On a read-only root a dump logs that it cannot open its file, such as `Can't open /tmp/keepalived.stats`, and keepalived continues. Add a second tmpfs at `/tmp` only if you use the dumps.

## The keepalived patch

keepalived is built from a pinned official source release with one [checked-in patch](../patches/). The build applies it with `patch -p1 --fuzz=0`, so source drift on a version bump fails the build instead of shipping an unpatched binary.

The patch restores the report for a track or notify script that could not be executed. keepalived redirects the script's stderr to `/dev/null` before `execve`. It then reports an exec failure through stderr and syslog, and a container has neither. Without the patch, a script whose interpreter the image lacks, or one on a `noexec` mount, fails with no symptom at all. A track script is the worse case. Its child exits 0 after the failed `execve`, keepalived reads that as the script succeeding, and the host holds the virtual IP through an outage of the service the script watches.

`KeepalivedScriptExecFailed` matches the line the patch makes visible, and the build-time test checks its three log strings against the shipped binary. The patch is dropped once a pinned keepalived release reports the failure itself.

## Verifying the image

The image is signed with cosign and carries a signed software bill of materials. [Checking a signature](https://github.com/cplieger/docs/blob/main/docs/images.md#checking-a-signature) and [Reading the software bill of materials](https://github.com/cplieger/docs/blob/main/docs/images.md#reading-the-software-bill-of-materials) show how to check both, with `docker-keepalived` as the app name.

## What the image contains

- Alpine Linux as the base image ([Docker Hub](https://hub.docker.com/_/alpine)), pinned by SHA digest.
- keepalived, built from the pinned [official](https://www.keepalived.org/) source tarball, whose SHA256 is checked at build time, so a mismatch fails the build. The build has the same features as Alpine's own package, which are nftables, libnl3, OpenSSL and JSON, with no SNMP and no systemd. The patches in [`patches/`](../patches/) are applied to that source first, so the shipped binary is not stock. Each patch header says what it changes and when it can be dropped.
- The Alpine runtime libraries keepalived links against, which are libnl3, libnftnl, libmnl and OpenSSL.

[Renovate](https://github.com/renovatebot/renovate) updates the dependencies. A new keepalived release triggers a version bump, a rebuild and a new image. The runtime libraries move forward at image build time, and a published image is rebuilt once its last successful build is older than a set interval. For a faster patch response, rebuild or pull on your own schedule, or run a [trivy](https://trivy.dev/) scan of the `latest` image.
