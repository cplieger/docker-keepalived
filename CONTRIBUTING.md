# Contributing to docker-keepalived

This image is a minimal Alpine wrapper around upstream
[keepalived](https://www.keepalived.org/), compiled from the pinned release
tarball with the patches in `patches/` applied. The notes below cover what is
specific to this repo; org-wide defaults are inherited from
[`cplieger/.github`](https://github.com/cplieger/.github).

## Layout

- `Dockerfile`: builds keepalived from the pinned upstream tarball
  (`KEEPALIVED_VERSION` + `KEEPALIVED_SHA256` build args, verified fail-closed
  before extraction) in a discarded builder stage, applies every file in
  `patches/` with `patch -p1 --fuzz=0`, writes the CycloneDX fragment the
  release SBOM picks up, copies the binary onto the digest-pinned Alpine base
  and wires the `HEALTHCHECK` and `ENTRYPOINT`. Renovate bumps the version
  against upstream tags and the `# repin:` marker lets it recompute the SHA256
  in the same commit.
- `patches/`: source patches applied at build time. Each header states what it
  changes and the condition under which it is dropped; the README's Security
  section repeats the drop condition for readers.
- `alerts/logql.yaml`: the recommended Loki rules. Every matcher keys on a
  format string in the pinned keepalived release, so a version bump can break a
  rule without touching this file; see the anchor list below.
- `tests/`: the two smoke tests and their shared fixture `keepalived.conf`.
- `compose.yaml`: the reference deployment.

There is no entrypoint script and no application source beyond these files:
keepalived runs as PID 1 with `--dont-fork --log-console --log-detail`.

## Design boundaries (please preserve)

- **Generic, upstream-only.** No env-var-to-config translation, no bundled
  track or notify scripts. The operator supplies `keepalived.conf` through the
  read-only `/etc/keepalived` bind mount.
- **No PID 1 wrapper.** keepalived is PID 1, so `docker stop` reaches it
  directly and a fatal exit ends the container with keepalived's own status
  (`6` when it finds no readable config, `2` when a child exits with a
  permanent CONFIG error). Do not add an init or supervisor layer; the exit
  status is how a failed boot is reported.
- **The healthcheck is `pgrep -P 1 -f '(^|/)keepalived([[:space:]]|$)'`.** It
  passes only for a keepalived child of PID 1, so a parent with no child does
  not read as healthy (a config with nothing to run) and neither does a
  `genhash` run, which is the same executable but no child of the daemon. `-f`
  matches the command line, so a child renamed through `vrrp_process_name`
  still counts; `tests/keepalived.conf` sets that directive so the healthy run
  proves it. Keep it exec-form and keep both `-P 1` and `-f`.
- **Build-time feature pins.** `--enable-nftables`, `--disable-bfd` and
  `--disable-iptables` are explicit so an upstream default flip cannot reach
  the image through an automerged bump; `tests/smoke.sh` asserts the resulting
  `--version` feature line.

## Tests

Two smoke tests cover two failure classes, and both block `ci / validate`.

`tests/smoke.sh` runs in the Dockerfile `test` stage against the freshly built
binary, so the image cannot be built without it passing. It asserts the exact
version, the feature parity line (NFTABLES and JSON present, BFD and IPTABLES
absent), that `keepalived -t` accepts `tests/keepalived.conf` and rejects the
same file with `script_user root` removed (the negative control that keeps the
config check from going vacuous), that a track script keepalived cannot execute
is reported (the behaviour `patches/` restores), the SBOM fragment, and that
every literal in its `for lit in` anchor list is still present in the shipped
binary. That list is the build-time link between `alerts/logql.yaml` and the
pinned release: when you change a matcher, change its anchor in the same PR,
and when a bump fails the anchor check, re-read the rule against the new
sources rather than deleting the anchor.

`tests/image-smoke.conf` is the per-app config for the shared runtime harness
`tests/image-smoke.sh`, which is synced from `cplieger/ci` and must not be
edited here. The harness boots the assembled image with `tests/keepalived.conf`
mounted at the default config path, waits for the baked healthcheck and for
`Starting VRRP child process` in the log, then `smoke_verify` drives a real
failover on the container's bridge interface: VI_TEST must take its VIP and
run its notify script, VI_UNSAFE's world-writable notify script must be refused
and never run, a failing tracked script must put VI_TEST in FAULT and release
the VIP, recovery must take it back, and a graceful stop must send a
priority-zero advert. It ends with three negative controls, each a second
container from the same image: with no config file the container must exit 6
on its own; with the fixture mounted under `--network none` (no `eth0`) the
VRRP child must reject the config and the parent must exit 2 with it rather
than stay up as a healthy container holding no VIP, and its log must carry the
two lines `KeepalivedPermanentError` selects (a source-time check in the
`.conf` proves the rule still selects both); and with a config that parses but
declares nothing the container must stay running and report `unhealthy` while
a `genhash` invocation is alive inside it, so a keepalived process that is not
a child of PID 1 cannot satisfy health. The first two require keepalived's
exact exit status, so they survive upstream rewording and fail on a crash or a
runner kill.

## Running checks locally

The build-time test runs inside `docker build`; the runtime test needs Docker,
Docker Compose, `jq` and GNU `timeout` on the host:

```sh
docker build -t docker-keepalived .
sh tests/image-smoke.sh docker-keepalived
```

The runtime test creates a container named `smoke-docker-keepalived-<pid>` on
the default bridge, with VRRP router ids 251 and 252 and the VIP
`192.168.255.254`, and three `smoke-docker-keepalived-<pid>-boot-*` containers
with `--network none`; it removes all of them on exit and never touches the
host network namespace. Lint the shell with
`shellcheck -S info tests/smoke.sh` and
`shellcheck -s sh -S info -e SC2034 tests/image-smoke.conf` (the `.conf` has no
shebang and its variables are read by the harness), and check the formatting
with `shfmt -d -i 2 -ci -bn tests/image-smoke.conf tests/image-smoke.sh
tests/smoke.sh`.

## Commits and PRs

This repo uses [Conventional Commits](https://www.conventionalcommits.org/)
parsed by git-cliff to generate release notes, so the subject becomes a
changelog line: `feat:` (Added), `fix:` (Fixed), `sec:` (Security),
`chore(deps):` (Dependencies). Edits under `alerts/` and to `*.md` do not
trigger a release. Open the PR against `main` and make sure `ci / validate` is
green before merging.

## Conduct and security

By participating you agree to the
[Code of Conduct](https://github.com/cplieger/.github/blob/main/CODE_OF_CONDUCT.md).
Report vulnerabilities via the
[security policy](https://github.com/cplieger/.github/blob/main/SECURITY.md),
never in a public issue.
