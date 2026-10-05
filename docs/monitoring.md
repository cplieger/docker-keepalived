# Monitoring and alerts

This page covers what keepalived writes to its log, how to read the current state of each instance and the alert rules that ship with the image. It is for operators who send container logs to Loki or watch them by hand.

## What keepalived logs

The image runs `keepalived --dont-fork --log-console --log-detail`, and the image itself writes no log lines of its own. Every VRRP state change, every track-script success and failure, and every config warning such as `Unsafe permissions found ... - disabling` goes to `docker logs keepalived` and to any log shipper that reads it. The healthcheck cannot see a stuck VRRP instance, so this log is where to look.

keepalived logs a track-script result and a VRRP state only when it changes. A standing fault therefore shows as one line when it starts, and nothing after it.

## Reading the current state

Three signals write a dump under `/tmp`, and two of them hold the state:

- `SIGUSR1` writes `keepalived.data`, with a `State = MASTER|BACKUP|FAULT` line for each instance.
- `SIGRTMIN+2` writes `keepalived.json`, with `state` and `wantstate` as numbers.
- `SIGUSR2` writes `keepalived.stats`, which holds counters only, such as adverts, master transitions, and packet and authentication errors. It has no state field.

`SIGRTMIN` depends on the C library, and in this image it is 35, so the JSON dump is `docker kill -s 37 keepalived`. Read a dump with `docker exec keepalived cat /tmp/keepalived.data`.

## Alerting

Ship the container log to Loki and load the rules in [`alerts/logql.yaml`](../alerts/logql.yaml) into [Loki's ruler](https://grafana.com/docs/loki/latest/alert/). Firing alerts go through your Alertmanager like any Prometheus alert. They cover:

| Alert | Fires when | Severity |
| --- | --- | --- |
| `KeepalivedTrackScriptFailed` | a track script has reported failed or timed out for 3 minutes with no recovery. The alert names the script | critical |
| `KeepalivedFaultState` | a VRRP instance has been in FAULT for 3 minutes and is out of the election. The alert names the instance | critical |
| `KeepalivedDuplicateMaster` | two hosts hold the same VRRP address, or this host refused an advert before it could tell | critical |
| `KeepalivedConfigError` | keepalived kept running after it rejected or ignored part of the config | warning |
| `KeepalivedConfigUnusable` | keepalived could not use all or part of its VRRP configuration | critical |
| `KeepalivedVIPOperationRefused` | the kernel refused to add or release a virtual address, route or rule | critical |
| `KeepalivedScriptDisabled` | keepalived refused to run a track or notify script and disabled it | critical |
| `KeepalivedScriptExecFailed` | keepalived started a track or notify script and could not execute it | critical |
| `KeepalivedPermanentError` | a child ended with a permanent error and the parent stopped, so the container restarts in a loop | critical |
| `KeepalivedChildRespawned` | a child process died and was respawned. The log line names which child | warning |
| `KeepalivedMemlockFailed` | `mlockall` failed, so `vrrp_no_swap` is inert and the VRRP child can be swapped out | warning |

Thresholds and the `severity` labels are starting points. Change the `container` selector and the `hostname` grouping to the labels your log collector sets, and route by whatever labels your Alertmanager uses.

### When the two state rules clear

`KeepalivedTrackScriptFailed` and `KeepalivedFaultState` read the latest status of each script and each instance rather than counting events. keepalived logs a status only when it changes, so a count over a window cannot tell a fault that recovered from one that did not. A counting rule would page on every rolling redeploy of a tracked service. The recovery line clears them, so a restart of a tracked service or a brief FAULT during a redeploy does not alert.

The `for: 3m` on both rules is deliberately longer than the tens of seconds a recreated tracked container takes to recover. If your tracked service takes longer than that to come back, raise `for`.

They also clear with no recovery behind them. Because keepalived logs a status only when it changes, a standing fault older than the lookback on each rule's `unwrap` leaves the window empty. The rule then reports no state, and your Alertmanager receives a resolved notification for a fault that is still there. Read the log before you treat a resolve as a recovery.

A resolve is a recovery only when the log shows one. For a track script, that is a `succeeded` line for the script. For an instance, that is the instance entering BACKUP or MASTER.

The lookback in `alerts/logql.yaml`, 7 days, sets how long a standing fault keeps paging. It is sized so that a fault that starts before a weekend still pages on Monday. No finite lookback keeps a standing fault paging forever. To lengthen it, raise the `[7d]` range in both rules. If a container you took out of service during a fault keeps paging for too long, lower it.

Two limits on your Loki ruler apply to that range. A range longer than `max_query_length` makes the rule evaluation fail with an error. A range longer than `max_query_lookback` does not fail, but the lookback silently shrinks to that limit.

A failing track script has one of two effects, and the state lines beside the alert show which. A script with no `weight` puts this host into FAULT and out of the VRRP election. A weighted script lowers this host's priority instead, so the host may still hold the virtual IP.

Any tracked object can put an instance into FAULT. That includes a failed track script, file or process, a tracked interface that went down, and an interface with no usable address. The log lines just before the FAULT name the cause. In FAULT, this host holds none of the instance's virtual addresses. The rule reads only this host's log and cannot see whether a peer took them over, so check the peers.

The FAULT matcher ignores case and accepts an optional colon on purpose. keepalived logs `Entering FAULT STATE` for a track-script cause. It logs `entering FAULT state` for an interface, address, tracked-file or tracked-process cause.

### Details of the other rules

`KeepalivedDuplicateMaster` fires when two hosts may hold the same VRRP address, which splits traffic to the virtual IP between them. Read the reason on the matched line first. Then check `auth_pass`, `virtual_router_id`, and that multicast passes in both directions. The rule has four legs.

The first two legs observe the conflict directly and name the offending peer. The first leg matches an address-owner conflict, which logs `CONFIGURATION ERROR ... please resolve`. It also matches an advert that carries this host's own address, which logs `equal priority advert received from remote host with our IP address`.

The second leg counts lower-priority adverts reaching a master. keepalived logs one line per advert. One or two also arrive during a legitimate failback, so the leg needs more than 5 lines in 30 minutes.

That count assumes a short `advert_int`. At the accepted maximum of 255 seconds, 30 minutes carries only about seven adverts. If your `advert_int` is long, raise the window or lower the threshold.

The third and fourth legs observe only that this host refused an advert before reading its fields. A refused advert never reaches the lines the first two legs match. If the sender is a real peer for this `virtual_router_id`, the refusal still produces two masters. This host never sees the peer's MASTER claim, so it elects itself. If the sender is a stray or spoofed advert from elsewhere, the match says nothing about who owns the address.

The third leg reads the reasons keepalived gives for refusing an advert:

- an auth password mismatch, or an auth type mismatch where neither side is AH
- a wrong VRRP version, or a VRRPv2 advert-interval mismatch
- unicast adverts on a multicast instance, or the reverse

keepalived names each of these once per cause, and not again until the instance changes state. The third leg therefore reports the start of the fault rather than a standing fault.

The fourth leg reads refusals that happen before keepalived reads any field of the advert:

- With `auth_hmac` configured, a missing, malformed, stale or replayed authentication trailer, an unknown key id, or a bad HMAC. A clock skewed past `time_window` is enough to cause one.
- With `check_unicast_src` set, an advert from an address outside this instance's `unicast_peer` list. A `min_ttl` or `max_ttl` on a `unicast_peer` line also sets `check_unicast_src`.
- An advert from a unicast peer whose TTL or hop limit falls outside that peer's `min_ttl` and `max_ttl` range.
- A multicast advert whose TTL is not 255. It was routed or forged, so a match here with none of the config causes above points at the network rather than at either `keepalived.conf`.

Five causes of two masters never reach this rule:

- A `virtual_router_id` mismatch logs nothing unless `global_defs` sets `log_unknown_vrids`.
- A mismatched `virtual_ipaddress` set is logged, but the advert is not refused.
- An `auth_type` mismatch where one side uses AH changes the IP protocol number of the adverts. Neither host receives the other's adverts or logs a reason.
- An address owner running `owner_ignore_adverts` drops every advert before the address-owner lines. It logs only `Dropping packet(s) ... since we are address owner`.
- A checksum refusal. One host with `v3_checksum_as_v2` or `unicast_chksum_compat` and a peer without it is enough to cause one.

The rule leaves `Invalid VRRPv2 checksum` and `Invalid VRRPv3 checksum` unmatched on purpose. A single corrupted advert on the wire logs the same line, and matching it would page critical for one bad packet.

`KeepalivedConfigError` fires when keepalived logs a config error and keeps running with it. It is a warning because the daemon keeps serving. Review your `keepalived.conf` for the line it names. It covers:

- an unknown keyword, whose directive keepalived ignores
- a parse error prefixed `(Line N)`, such as an invalid directive value
- an instance disabled by a config fault, such as an interface that cannot do multicast
- a reload keepalived refused, logged as `Cannot change ... at a reload - please restart keepalived`. Every edit in that file stays unapplied while the old config keeps serving.
- an `auth_hmac` `active_key` that names no defined key. keepalived drops the whole authentication extension and the instance runs unauthenticated, so the fourth leg of `KeepalivedDuplicateMaster` cannot report for it.

An instance disabled by a config fault is not serving, and it pages separately. Every config fault of that kind ends in FAULT state, which `KeepalivedFaultState` reports at critical. A config keepalived could not read, or one with nothing to run, is `KeepalivedConfigUnusable`. A script keepalived will not run is `KeepalivedScriptDisabled`. A config fault that stops a started child is `KeepalivedPermanentError`.

`KeepalivedConfigUnusable` fires when keepalived could not turn all or part of your config into running VRRP instances. Read the matched line and find the file it names, because the scope depends on the file:

- An unusable main config is fatal. If keepalived cannot open or read it, or will not accept it as a regular non-executable file, it exits before any child starts. The container restarts in a loop and the healthcheck never reports healthy. `KeepalivedPermanentError` stays silent because no child died. These lines carry no `(Line N)` prefix.
- A main config that does not exist at all, such as an empty or missing mount, is invisible to this rule. keepalived exits with status 6 the same way, but it logs only its start and stop banners. The restart loop is the signal.
- A file pulled in by plain `include` that keepalived cannot use is skipped, and its directives never apply. That happens at startup as well as on reload, while the rest of the config keeps serving.
- A file pulled in under the `global_defs` option `include_check`, or by an `includer`-family directive, is fatal at startup like the main config. These lines carry a `(Line N)` prefix naming the line the include sits on.
- `has no configuration to run` means the config parsed but no part of it started a child, usually an empty file or a `global_defs` block alone. The daemon stays up and idle, nothing crashes, and the healthcheck reports unhealthy once its retries are spent.

keepalived uses a config file only when it is a regular file with no execute bit set. Check your `keepalived.conf`, its includes and their modes. Then check the virtual IP state of whatever the line named.

`KeepalivedVIPOperationRefused` fires when keepalived asked the kernel to add or release a virtual address, route or rule and the kernel refused. keepalived carries on as though the operation worked, in both directions. Nothing else reports it. No track script failed, no instance is in FAULT for the add case, and the healthcheck stays green. Read the netlink message type on the matched line first, because the two directions mean opposite things.

An `RTM_NEW` refusal, or a `Not adding address` line, is a failed add on becoming MASTER. keepalived logs `Entering MASTER STATE` before it makes the request, and marks the addresses as set whatever the answer, so it does not ask again. This host keeps advertising as MASTER and winning the election while the virtual IP is on no host. `notify_master` has already run.

An `RTM_DEL` refusal is a failed release on leaving MASTER. keepalived has already logged `Entering BACKUP STATE` or `Entering FAULT STATE`, and it clears its own record of the addresses anyway. Its record and the kernel's then disagree, and the error number on the line says which way:

- `EPERM` means the capability was missing, so the matching add was refused too and this host never held the address. The `RTM_NEW` line before it is the real signal.
- An error number naming the object as absent means it was already gone, and no peer is in conflict.
- Any other error number leaves the address, route or rule on this host while a peer takes it over. That is the conflict `KeepalivedDuplicateMaster` reads from the other side.

The usual cause is a container without `NET_ADMIN`. The raw VRRP socket needs only `NET_RAW`, so keepalived starts, elects and sends adverts normally, and only the address operation is refused. The [configuration reference](../README.md#configuration-reference) lists both capabilities. The other cause is an interface that went away after keepalived read the config, which logs the `Not adding address` form and names the interface. Check the container's capabilities and the interface the instance names.

`KeepalivedScriptDisabled` fires when keepalived would not run a script and disabled it. The same permission and lookup checks refuse a `track_script` and a `notify_master`, `notify_backup` or `notify_fault` script alike. Most matched lines do not say which kind it was. Only `Disabling track script` is unambiguous, so find the script the line names before you act.

A refused track script means the object it tracks is never evaluated. This host's priority never drops, and it keeps the virtual IP through an outage of the service the script watches. A refused notify script means the state change still happens but its side effect does not. An address or route the new MASTER should install never appears. Nothing else reports either case, because the daemon runs, VRRP works and the healthcheck stays green.

The usual cause is path permissions under `enable_script_security`, as [Configuration](configuration.md#script-permissions-under-enable_script_security) describes. The rule also fires for a script keepalived cannot find, cannot execute as its run-as user, or cannot set the uid or gid for.

`KeepalivedScriptExecFailed` fires when keepalived started a child for a track or notify script and the exec failed, so the script never ran. The line names the path. The checks keepalived runs while it reads the config cannot see this, which is why `KeepalivedScriptDisabled` does not report it. The path, owner and permissions are in order, and the program behind them is not. The two usual causes are a first line naming an interpreter the image does not have, and a script on a `noexec` mount.

For a track script, the consequence is worse than a refusal. The child exits 0, and keepalived reads that as the check passing and logs `VRRP_Script(name) succeeded`. This host then keeps the virtual IP through an outage of the service the script watches. For a notify script, the state change still happens and its side effect does not.

`KeepalivedPermanentError` fires when a keepalived child ends with a permanent error. The parent logs `exited with permanent error CONFIG`, or the same line with `FATAL` or a missing permission as the reason, and then stops too. The container exits and the restart policy restarts it in a loop, so this host holds no virtual IP at all. Read the error logged just before that line for the cause.

That one line covers a missing interface and two VRRP instances that share a `virtual_router_id` on one interface. It also covers any other config the VRRP child refuses outright. `KeepalivedChildRespawned` cannot fire for these, because the parent stops instead of respawning the child.

`KeepalivedChildRespawned` fires when a keepalived child died and the parent respawned it. The log line names the child. A VRRP child respawned while it was MASTER moves its virtual IPs off this host and back, which breaks every long-lived connection through them. A respawn while it was BACKUP shows no ownership change by itself, so read the state lines before it. A respawned Healthcheck child leaves the virtual IPs in place and only pauses LVS real-server checking.

A child that had run for at least a minute is respawned at once, before the next probe. The healthcheck normally stays green, and this alert is the only report of the death. A child that keeps dying within its first minute is restarted with a growing delay of up to 60 seconds. That can turn the healthcheck unhealthy. The alert fires on every death either way, and the log lines just before it give the child's exit status.

`KeepalivedMemlockFailed` fires when the config asks for `vrrp_no_swap` or `checker_no_swap` and `mlockall` fails. The option is then inert for the life of the process, and the child can be swapped out. keepalived logs this once at startup with the error number appended, and carries on, so nothing else reports it. Read the error number, then check the container's locked-memory limit, `RLIMIT_MEMLOCK`, and whether the container has `CAP_IPC_LOCK`. [Configuration](configuration.md#locked-memory-for-vrrp_no_swap) shows how to raise the limit.

### What a takeover looks like in the log

These rules read what keepalived reports about itself, and a completed takeover is in that report. The host that stops logs `(NAME) sent 0 priority`. The host that takes over logs `(NAME) Backup received priority 0 advertisement` before `Entering MASTER STATE`. A master that loses an election while alive logs `Master received advert from <peer> with higher priority P, ours Q`, or `... with same priority P but higher IP address than ours`. The two priority-0 lines need `--log-detail`, and the image passes it, so every line above is in `docker logs keepalived` already.

Only a host that dies outright is silent. The host that takes over then logs `Entering MASTER STATE` and nothing else, which every election at boot logs too. A rule for that case has to know which host should hold the virtual IP. That decision is yours, and the rule belongs in your own rule set beside these.

### Matchers and keepalived versions

Each matcher keys on wording from a format string in the pinned keepalived release. If you run these rules against another keepalived version, check each matcher against that version's log wording.

Nine rules match through a regex rather than a plain substring. `KeepalivedTrackScriptFailed` binds the status word to its own field with a word boundary, and `KeepalivedFaultState` spans two upstream casings. `KeepalivedDuplicateMaster`, `KeepalivedConfigError`, `KeepalivedConfigUnusable`, `KeepalivedPermanentError`, `KeepalivedScriptDisabled`, `KeepalivedScriptExecFailed` and `KeepalivedVIPOperationRefused` each alternate over several patterns. Read a matcher edit for its regex meaning as well as for wording drift.

The build-time test in `tests/smoke.sh` checks the distinctive strings of every matcher against the shipped keepalived binary. A keepalived update that rewords one fails the build.

The test cannot check the bare status word `failed`. keepalived stores that word apart from the format string it lands in. The binary also carries unrelated strings that contain it, so a search for it could never fail. Re-read that word against the keepalived sources on every keepalived update.
