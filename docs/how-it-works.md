# How docker-keepalived works

This page explains what the image runs and what its healthcheck and exit codes mean. It is for operators who want to know why the container is healthy, unhealthy or stopped.

## Design

- The image is generic and runs keepalived only. It bakes in no track scripts, so it works for any VRRP topology without inheriting someone else's check logic.
- All configuration arrives through one read-only mount of `/etc/keepalived`, and the published example adds no writable bind mount.
- The image has no init or supervisor process. `keepalived --dont-fork` runs as PID 1, so the stop signal from `docker stop` reaches it at once, and a fatal exit ends the container with keepalived's own exit status.

## What the image runs

The entrypoint is `keepalived --dont-fork --log-console --log-detail`, so every VRRP state change, track-script result and config warning goes to `docker logs keepalived`. keepalived is compiled from a pinned official source release with one patch applied, described in [Security](security.md#the-keepalived-patch). The image also ships keepalived's `genhash` digest helper, which you use to fill in an `HTTP_GET` checker's digest.

## Healthcheck and exit codes

The built-in healthcheck runs `pgrep -P 1 -f '(^|/)keepalived([[:space:]]|$)'` every 30 seconds, with a 5-second timeout, 3 retries and a 15-second start period. It passes while PID 1 has a keepalived child process, the VRRP process or the LVS checker. The parent alone does not count, and neither does a `genhash` run, which is the same executable but not a child of the daemon. The probe matches the child's command line, so a `vrrp_process_name` or `checker_process_name` rename still passes.

`healthy` means the daemon is up and running the configuration it was given, which is what `depends_on: condition: service_healthy` waits for. `unhealthy` means the daemon is up and no subsystem in its configuration produced a child. That is a config that parsed but gave keepalived nothing to run, such as an empty file or `global_defs` alone, which logs `keepalived has no configuration to run`. It is also a child that keeps dying within its first minute and sits in the parent's growing respawn delay.

A config keepalived cannot start on reaches neither state, because keepalived is PID 1 and its exit ends the container. `docker ps -a` shows the exit status and the restart count:

| Cause | Exit status | Log |
| --- | --- | --- |
| No `keepalived.conf` in the mount | 6 | Only the start and stop lines, no error |
| A `keepalived.conf` that is unreadable, not a regular file, or executable | 6 | The configuration error |
| A config the VRRP child rejects, such as one naming an interface the container does not have | 2 | `exited with permanent error CONFIG` |

The probe does not report a stuck VRRP instance. A child that dies after running for at least a minute is respawned at once and passes the probe. Watch the log and the alert rules for both, as [Monitoring and alerts](monitoring.md) describes.
