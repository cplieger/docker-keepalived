# Configuration

This page covers script permissions, config file checks, locked memory, reloads, multicast and IPv6 router advertisements. It is for readers who have the quick start running and write their own `keepalived.conf` for this image.

## Where settings live

Every setting lives in `keepalived.conf`, in the folder you mount read-only at `/etc/keepalived`. The image reads no environment variables, generates no config and ships no scripts. Put your check and notify scripts in a `scripts` folder beside `keepalived.conf` and name them by their path inside the container, such as `/etc/keepalived/scripts/check_app.sh`. The [keepalived documentation](https://www.keepalived.org/) is the reference for every keyword.

## Script permissions under enable_script_security

Set `enable_script_security` in `global_defs`. keepalived then refuses to run a script when any part of its path inside the container is writable by a user other than root. It disables the track script and names it in the log:

```text
Unsafe permissions found for script '/etc/keepalived/scripts/check_app.sh' - disabling.
Disabling track script chk_app due to insecure
```

Inside the container, `/etc/keepalived` has the ownership and mode of the host folder you mount. So these must hold on the host:

- The folder you mount at `/etc/keepalived`, and its `scripts` folder, belong to `root:root` and are not group- or world-writable. Mode 755 is fine. Mode 770 is not, because a group-writable folder counts as writable by non-root.
- Each track and notify script file also belongs to root and is not group- or world-writable. keepalived checks the file itself as well as the folders above it.

A host folder can inherit non-root ownership from the folder above it. Fix it on each host with:

```bash
chown -R root:root /path/to/keepalived
chmod 755 /path/to/keepalived /path/to/keepalived/scripts
# script files must also be non-group/world-writable (keepalived checks the file too)
chmod 644 /path/to/keepalived/keepalived.conf
find /path/to/keepalived/scripts -type f -exec chmod 755 {} +
```

Without `enable_script_security` these script rules do not apply, but you should set it.

## Config file checks

One check applies whether or not `enable_script_security` is set. keepalived does not use a config file that is not a regular file or that has an execute bit set, and logs `Configuration file '...' is not a regular non-executable file - skipping`. For your mounted `keepalived.conf` that is fatal at startup. keepalived exits before it starts VRRP, and the restart policy restarts the container in a loop. `KeepalivedPermanentError` stays silent, because no child process died. Keep `keepalived.conf` at mode 644, whatever else you set.

The same line for a file pulled in with `include` means keepalived skipped that file and carried on with the rest of the config.

## Scripts that never run

A script that passes every check above can still never run, in two ways:

- Its first line names an interpreter the image does not have. The base is Alpine, so `#!/bin/bash` is one of them. Use `#!/bin/sh`.
- It sits on a filesystem mounted `noexec`.

Both fail when keepalived starts the script, not when it reads the config, so the permission warnings never appear. The image reports both as `Error exec-ing command '/etc/keepalived/scripts/check_app.sh', error <n>: <reason>` in `docker logs`, and `KeepalivedScriptExecFailed` in [`alerts/logql.yaml`](../alerts/logql.yaml) is the rule for it. Watch for it on a track script in particular. keepalived reports the failed start as the check having succeeded, so the host keeps the virtual IP through an outage of whatever that script was watching.

## Locked memory for vrrp_no_swap

The image needs no resource limits to run, with one exception. If your `keepalived.conf` sets `vrrp_no_swap` or `checker_no_swap`, raise the container's locked-memory limit too, or the option does not do what it says.

Those options make the child process call `mlockall()`, and `RLIMIT_MEMLOCK` counts locked address space, not resident memory.

A container that sets no `ulimits:` inherits the Docker daemon's own limit, which is 8 MiB on a systemd host unless the daemon's unit says otherwise. This image's VRRP child maps about 7.4 MiB of program text and shared libraries before its first allocation, 4.8 MiB of it OpenSSL's libcrypto on amd64. So 8 MiB leaves it almost no room, and 64 KiB, the kernel default on hosts with no systemd raise, leaves it none at all. Add this to the service in `compose.yaml`:

```yaml
    ulimits:
      memlock:
        soft: 67108864  # 64 MiB, ~8x the child's mapped size
        hard: 67108864
```

`docker logs` tells the two failure modes apart:

- The limit is below the child's mapped size. `mlockall` fails at startup, keepalived logs `Unable to lock process in memory - Cannot allocate memory` once, and carries on with `vrrp_no_swap` inert from then on. The `KeepalivedMemlockFailed` rule catches it.
- The limit is just above it. The lock succeeds and a later allocation is refused instead. keepalived prints `Keepalived: Resource temporarily unavailable` with no timestamp, because it comes from `perror` rather than the log. The VRRP child exits with status 204 and the parent respawns it, which moves the virtual IP away and back. The `KeepalivedChildRespawned` rule catches it.

In the second case, the healthcheck stays green when the child had run for at least a minute. The parent then respawns it at once, and the probe never sees the gap. A child that keeps dying within its first minute is respawned with a growing delay of up to 60 seconds and can turn the healthcheck unhealthy. For any child death, keepalived prints `Please log an issue at ...`, so that line is not evidence of a keepalived bug.

Check what your host granted:

```bash
docker exec keepalived grep 'Max locked memory' /proc/1/limits
```

Size the limit with one more fact in mind. keepalived's interface table gains an entry for every interface the host has ever had and does not release it, as [keepalived issue #2709](https://github.com/acassen/keepalived/issues/2709) describes. Every container start on the host creates a veth interface. On a busy host a finite limit sets how long the child lives rather than preventing the exit. Headroom buys time and is not a cure.

## Reloading without a restart

To apply a config change without restarting the container, which would move the virtual IP:

```bash
docker kill -s HUP keepalived
```

keepalived rereads `keepalived.conf` and applies the changes. Unchanged instances keep their VRRP state, and only changed instances renegotiate briefly.

Seven settings cannot change this way. They are the top-level `net_namespace`, `net_namespace_ipvs` and `instance`, and the `global_defs` entries `nftables`, `nftables_ipvs`, `tmp_config_directory` and `disable_local_igmp`. For a change to one of them, keepalived logs `Cannot change ... at a reload - please restart keepalived`. The line names keepalived's internal field rather than the directive, so its text and the keyword you wrote differ. It keeps the old configuration and never signals its VRRP child, so every other edit in the file is discarded too. Run `docker restart keepalived` instead. The `KeepalivedConfigError` rule catches a refused reload.

## Multicast and unicast

VRRP adverts go to the multicast addresses `224.0.0.18` for IPv4 and `ff02::12` for IPv6 (RFC 5798). That is why the container uses host networking. `NET_BROADCAST` is not required.

If multicast does not pass between your hosts, list the other hosts with `unicast_peer` in each `vrrp_instance`, and keepalived sends its adverts to them directly.

## IPv6 router advertisements with radvd

If you advertise IPv6 prefixes on your LAN with radvd on more than one host, keepalived can hold a floating link-local address and radvd can send its router advertisements from it with `AdvRASrcAddress`. Only the host holding that address then advertises. It has to be a link-local address, because hosts discard a router advertisement sent from a global one. [docker-radvd](https://github.com/cplieger/docker-radvd) is an image by the same author whose README shows the radvd side of this pairing.
