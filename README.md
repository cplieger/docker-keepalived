# docker-keepalived

[![Image Size](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/cplieger/docker-keepalived/badges/size.json)](https://github.com/cplieger/docker-keepalived/pkgs/container/docker-keepalived) [![Platforms](https://img.shields.io/badge/platforms-amd64%20%7C%20arm64-blue)](https://github.com/cplieger/docker-keepalived/pkgs/container/docker-keepalived) [![base: Alpine](https://img.shields.io/badge/base-Alpine-0D597F?logo=alpinelinux)](https://github.com/cplieger/docker-keepalived/blob/main/Dockerfile) [![SBOM](https://img.shields.io/badge/SBOM-SPDX-1D4ED8)](https://github.com/cplieger/docker-keepalived/releases)

<!-- hub-overview BEGIN -->
docker-keepalived runs [keepalived](https://www.keepalived.org/) in a container, so two or more Linux hosts share a virtual IP address that moves to a healthy host when one fails. You write the `keepalived.conf`. The image does not generate one from settings.

## What it does

docker-keepalived keeps one address reachable while a host, or a service on it, goes down.

- Moves the virtual IP to another host within seconds when the host holding it stops sending adverts.
- Moves it when a check script you write reports that your service is down.
- Rereads a changed `keepalived.conf` on a reload signal, without restarting the container.
- Reports every failover and failed check in `docker logs`, with 11 Loki alert rules ready to load.

## Who it is for

docker-keepalived is built for admins who already write keepalived configurations and want keepalived in a container. It runs a pinned official keepalived release, patched so a check script that cannot start shows in the log.

You need two or more Linux hosts with Docker on one network, on `amd64` or `arm64`. The container runs as root with host networking and the `NET_ADMIN` and `NET_RAW` capabilities.

Three other options suit other setups:

- Consider your distribution's keepalived package to run it on the host itself, which its maintainers call the quickest install.
- Consider [osixia/keepalived](https://github.com/osixia/container-keepalived) if you want the configuration generated from environment variables.
- Consider [kube-vip](https://kube-vip.io/) if you want a virtual IP for a Kubernetes control plane or LoadBalancer services.

docker-keepalived is free software under the Apache-2.0 license. keepalived itself is under GPL-2.0-or-later.
<!-- hub-overview END -->

## Quick start

The image is on GitHub Container Registry and Docker Hub, for `amd64` and `arm64`. This is the [`compose.yaml`](compose.yaml) in this repository. Besides `latest`, each release is tagged with its full, minor and major version, such as `v2.4.0`, `v2.4` and `v2`, so every host can run the same release. These are the image's own version numbers, separate from the keepalived version inside it.

```yaml
services:
  keepalived:
    image: ghcr.io/cplieger/docker-keepalived:latest
    container_name: keepalived
    restart: unless-stopped

    # VRRP sends multicast adverts on your LAN, so it needs host networking and these two capabilities.
    network_mode: host
    cap_add:
      - NET_ADMIN
      - NET_RAW

    # Put keepalived.conf in ./keepalived and your scripts in ./keepalived/scripts before the first start.
    # Give the folder to root and let only root write to it, or keepalived disables your scripts.
    volumes:
      - "./keepalived:/etc/keepalived:ro"
```

On each host:

1. In the folder that holds `compose.yaml`, create a `keepalived` folder and a `keepalived/scripts` folder inside it.
2. Save this as `keepalived/keepalived.conf`. Replace `eth0` with the host's LAN interface, `192.0.2.250/24` with the address to share and its prefix length, and `changeme` with a password of your own, the same on every host. On the other hosts, change `state MASTER` to `state BACKUP` and `priority 150` to `priority 100`.

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

3. Save this check script as `keepalived/scripts/check_app.sh`. It passes while a web server answers on port 80 of the host, so change the address to the service you want to watch. Keep the `#!/bin/sh` line, because the image is based on Alpine and has no `bash`.

   ```sh
   #!/bin/sh
   wget -q --spider http://127.0.0.1:80/
   ```

4. Give both folders to root and let only root write to them:

   ```bash
   sudo chown -R root:root keepalived
   sudo chmod 755 keepalived keepalived/scripts
   sudo chmod 644 keepalived/keepalived.conf
   sudo find keepalived/scripts -type f -exec chmod 755 {} +
   ```

5. Run `docker compose up -d`.

Run `docker logs keepalived`. You should see `Starting VRRP child process`. If you see `Unsafe permissions found for script`, keepalived disabled that script because step 4 was skipped.

## Configuration reference

Every setting lives in `keepalived.conf`. The image reads no environment variables. keepalived reads the file at start, and again when you run `docker kill -s HUP keepalived`. A reload keeps the state of unchanged instances, and changed ones renegotiate briefly. Seven settings need a full restart instead, listed in [Configuration](docs/configuration.md#reloading-without-a-restart). If multicast does not pass between your hosts, list them with `unicast_peer`, as [Configuration](docs/configuration.md#multicast-and-unicast) shows.

| Mount | Description |
| --- | --- |
| `/etc/keepalived` | Your `keepalived.conf` and the scripts it names. Mount it read-only. It must be root-owned and not group- or world-writable when `enable_script_security` is set |

| Capability | Why it is needed |
| --- | --- |
| `NET_ADMIN` | Adding and removing the virtual IP, and setting socket options |
| `NET_RAW` | Building VRRP packets on raw sockets, and ICMP probes |

The container uses `network_mode: host`, because VRRP adverts are multicast on your LAN segment and a container network would isolate them. If your `keepalived.conf` sets `vrrp_no_swap` or `checker_no_swap`, raise the container's locked-memory limit as [Configuration](docs/configuration.md#locked-memory-for-vrrp_no_swap) shows, or the option does nothing.

## Security

The container runs as root by design. keepalived needs `NET_ADMIN` to add and remove the virtual IP on a host interface and `NET_RAW` to build VRRP packets. Grant those two with `cap_add` rather than `privileged`. Mount `/etc/keepalived` read-only. It is the only bind mount the image needs, and a writable one would let the container change the scripts keepalived runs as root. Set `enable_script_security` so keepalived refuses any script a non-root user could change. `auth_pass` travels in clear text, so VRRP authentication guards against a misconfigured peer, not an attacker.

One scan finding is accepted, AVD-DS-0002 "image user should not be root", because a non-root user cannot manage the virtual IP. The keepalived binary carries one patch, which reports a script keepalived could not execute. It is dropped once a keepalived release reports that failure itself. [Security](docs/security.md) covers the read-only profile, signature checks and what the image contains.

## Troubleshooting

The healthcheck passes while keepalived has a child process running, either its VRRP process or its LVS checker. Unhealthy means keepalived is up but has nothing to run, such as an empty file or a file with only `global_defs`. It also means a child process keeps dying within a minute of starting. A config keepalived cannot start on stops the container instead, and `docker ps -a` shows the exit code and the restart count. The probe does not see a stuck VRRP instance, so watch `docker logs keepalived`.

- `Unsafe permissions found for script ... - disabling`. A folder or script is writable by a non-root user. Repeat step 4 of the quick start.
- `Configuration file '...' is not a regular non-executable file - skipping`, and the container restarts in a loop. Run `sudo chmod 644 keepalived/keepalived.conf`.
- `Error exec-ing command '...'`. The script could not start. Its first line names a program the image lacks, such as `bash`, or it sits on a `noexec` mount. keepalived counts that check as passed, so the host keeps the address.
- `Unable to lock process in memory`, or `Resource temporarily unavailable` and a respawned child. `vrrp_no_swap` needs a higher locked-memory limit.

[Configuration](docs/configuration.md) and [How it works](docs/how-it-works.md#healthcheck-and-exit-codes) have the detail.

## Monitoring

keepalived writes every VRRP state change, check-script result and config error to `docker logs`. Eleven Loki alert rules ship in [`alerts/logql.yaml`](alerts/logql.yaml). [Monitoring and alerts](docs/monitoring.md) lists them, shows how to load them and how to read the current state of each instance.

## Documentation

- [Configuration](docs/configuration.md) covers script permissions, locked memory, reloads and IPv6 router advertisements.
- [How docker-keepalived works](docs/how-it-works.md) covers the design, what the image runs, the healthcheck and the exit codes.
- [Monitoring and alerts](docs/monitoring.md) lists the alert rules and the state dumps.
- [Security](docs/security.md) covers the privilege model, the read-only profile, the patch and image signatures.

## Credits

This project packages [keepalived](https://github.com/acassen/keepalived) into a container image. All credit for the daemon goes to its maintainers, Alexandre Cassen and the keepalived community.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the layout and the tests, and open an issue first for a larger change.

## Disclaimer

This project is built with care and follows security best practices, but it is intended for personal / self-hosted use. No guarantees of fitness for production environments. Use at your own risk.

This project was built with AI-assisted tooling using [Claude](https://claude.com), [GPT](https://openai.com), and [Kiro](https://kiro.dev). The human maintainer defines architecture, supervises implementation, and makes all final decisions.

## License

Apache-2.0. See [LICENSE](LICENSE). The image carries the license text of every bundled component under `/usr/share/licenses/`. The Alpine packages in the image ship no license file upstream, so their license texts are kept under `licenses/` in this repository and copied in.

The bundled component is keepalived itself, which is GPL-2.0-or-later. The build fetches the pinned release tarball `https://www.keepalived.org/software/keepalived-<version>.tar.gz`, where `<version>` is the `KEEPALIVED_VERSION` build argument in the [`Dockerfile`](Dockerfile) without its leading `v`, verifies its SHA256, and applies one checked-in patch, [`patches/0001-report-a-script-that-could-not-be-executed.patch`](patches/0001-report-a-script-that-could-not-be-executed.patch), which is a local modification with no upstream commit behind it and is therefore part of the source the shipped binary is built from. keepalived's own `COPYING` travels in the image at `/usr/share/licenses/keepalived/COPYING`, and the upstream project is [acassen/keepalived](https://github.com/acassen/keepalived). That tarball, this repository's `Dockerfile` and the files in `patches/` are the complete recipe for the binary in the image, which is how anyone who receives it gets the corresponding source.

`patches/` is an exception. It holds a modification to keepalived's own source, so that file stays GPL-2.0-or-later under upstream's terms. Its header states what it changes and the condition for removing it.
