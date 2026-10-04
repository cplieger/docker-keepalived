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

`KeepalivedTrackScriptFailed` and `KeepalivedFaultState` read the latest status of each script and each instance rather than counting events. They clear when the recovery line arrives and stay quiet through a restart of a tracked service. Raise their `for: 3m` if your tracked service takes longer than that to come back.

They also clear with no recovery behind them. Because keepalived logs a status only when it changes, a standing fault older than the lookback on each rule's `unwrap` leaves the window empty. The rule then reports no state, and your Alertmanager receives a resolved notification for a fault that is still there. Read the log before you treat a resolve as a recovery. The lookback in `alerts/logql.yaml`, 7 days, sets how long a standing fault keeps paging.

### Details of the other rules

`KeepalivedDuplicateMaster` observes a conflict directly for an address-owner conflict and for an advert that carries this host's own IP address. Repeated lower-priority adverts observe it from the master's side. It also fires when this host rejects a peer's adverts, which produces the same two masters.

The rejection causes it reads are:

- an auth password mismatch, or an auth type mismatch where neither side is AH
- a wrong VRRP version, or a VRRPv2 advert-interval mismatch
- unicast adverts on a multicast instance, or the reverse
- a missing or invalid authentication extension
- an address outside the `unicast_peer` list
- a TTL or hop-limit failure

`KeepalivedConfigError` covers an unknown keyword, a parse error prefixed `(Line N)`, an instance disabled by a config fault, a reload keepalived refused, and an `auth_hmac` `active_key` that names no defined key.

`KeepalivedConfigUnusable` covers a config file keepalived could not open or read, a file it would not accept as a regular non-executable file, and a config that parsed with nothing to run. The scope depends on the file:

- An unusable main config exits, and the container restarts in a loop at startup.
- A file pulled in by plain `include` is skipped and its directives never apply, at startup as well as on reload, while the rest of the config keeps serving.
- A file pulled in under `include_check` or an `includer`-family directive is fatal like the main config. The `(Line N)` prefix on the line tells an include from the main file.
- A main config that does not exist at all is invisible to this rule. It shows as the startup restart loop instead.

`KeepalivedVIPOperationRefused` has two directions. A refused add, or an interface that disappeared, leaves this host advertising as MASTER with the virtual IP on no host. A refused release leaves keepalived's record and the kernel's in disagreement, and the error number says which way:

- `EPERM` means the matching add was refused too, and this host never held the address.
- An error number naming the object as absent means it was already gone.
- Any other error number leaves the address on this host while a peer takes it over.

`KeepalivedScriptDisabled` covers a refused track script, which means this host never fails over on that check, and a refused notify script, which means the side effect of a state change never runs. The container stays healthy in both cases.

`KeepalivedScriptExecFailed` sees what the config checks cannot, a first line naming an interpreter the image does not have, or a script on a `noexec` mount. A track script that fails this way is read as having succeeded, so the host keeps the virtual IP.

`KeepalivedPermanentError` covers a missing interface, a duplicate `virtual_router_id`, and any other config the VRRP child refuses outright.

### What a takeover looks like in the log

These rules read what keepalived reports about itself, and a completed takeover is in that report. The host that stops logs `(NAME) sent 0 priority`. The host that takes over logs `(NAME) Backup received priority 0 advertisement` before `Entering MASTER STATE`. A master that loses an election while alive logs `Master received advert from <peer> with higher priority P, ours Q`, or `... with same priority P but higher IP address than ours`. The two priority-0 lines need `--log-detail`, and the image passes it, so every line above is in `docker logs keepalived` already.

Only a host that dies outright is silent. The host that takes over then logs `Entering MASTER STATE` and nothing else, which every election at boot logs too. A rule for that case has to know which host should hold the virtual IP. That decision is yours, and the rule belongs in your own rule set beside these.
