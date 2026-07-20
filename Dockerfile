# check=error=true

# Renovate bumps KEEPALIVED_VERSION via the org-wide Dockerfile ARG
# customManager (github-tags). KEEPALIVED_SHA256 pins the upstream dist
# tarball and must be recomputed in the same PR (github-tags exposes the git
# sha, not the tarball hash, so the bump PR carries a stale hash and
# fail-closes the build until it is updated):
# curl -sL https://www.keepalived.org/software/keepalived-<X.Y.Z>.tar.gz | sha256sum
# renovate: datasource=github-tags depName=acassen/keepalived
ARG KEEPALIVED_VERSION=v2.4.3
ARG KEEPALIVED_SHA256=cb5b14543371e8949a848e5a476567d21c961b2f9f7b82909786bd4cd3c96ae7

# ---------------------------------------------------------------------------
# Builder stage — compiles keepalived from the pinned, SHA256-verified
# upstream source tarball with feature parity to Alpine 3.24-stable's
# community/keepalived package: nftables (libnftnl+libmnl), libnl3, OpenSSL,
# JSON; no systemd, no SNMP. Discarded; only the stripped binary ships.
# ---------------------------------------------------------------------------
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

# Build deps are build-only (this stage is discarded; only the compiled
# binary reaches the runtime stage), so their exact versions never ship and
# are intentionally left unpinned: they track whatever the Alpine 3.24 repo
# serves at build time (the digest pins the base image, not the apk
# repository index). keepalived itself stays version+SHA pinned below, since
# it is the shipped artifact.
# hadolint ignore=DL3018
RUN apk add --no-cache \
        build-base \
        libmnl-dev \
        libnftnl-dev \
        libnl3-dev \
        linux-headers \
        openssl-dev \
        pkgconf

ARG KEEPALIVED_VERSION
ARG KEEPALIVED_SHA256

WORKDIR /build/keepalived
# Fetch the upstream dist tarball fail-closed: a hash mismatch breaks the
# build. configure flags mirror the Alpine 3.24-stable APKBUILD
# (--enable-json --disable-systemd plus the same prefix/sysconfdir/
# localstatedir), minus --with-init=openrc (no init system in the container;
# keepalived runs as PID 1) and plus explicit --enable-nftables /
# --disable-iptables: the APKBUILD gets nftables implicitly from its
# makedepends and iptables-less builds implicitly from their absence, and
# being explicit makes configure fail loudly instead of silently dropping
# the feature (the test stage's build-options assertion is the backstop).
RUN wget -q --tries=3 --timeout=30 \
      "https://www.keepalived.org/software/keepalived-${KEEPALIVED_VERSION#v}.tar.gz" \
    && echo "${KEEPALIVED_SHA256}  keepalived-${KEEPALIVED_VERSION#v}.tar.gz" | sha256sum -c - \
    && tar xzf "keepalived-${KEEPALIVED_VERSION#v}.tar.gz" --strip-components=1 --no-same-owner \
    && rm "keepalived-${KEEPALIVED_VERSION#v}.tar.gz" \
    && ./configure \
        --prefix=/usr \
        --sysconfdir=/etc \
        --mandir=/usr/share/man \
        --localstatedir=/var \
        --enable-json \
        --enable-nftables \
        --disable-iptables \
        --disable-systemd \
    && make -j"$(nproc)" \
    && install -D -m 755 bin/keepalived /out/usr/sbin/keepalived \
    && strip /out/usr/sbin/keepalived

# ---------------------------------------------------------------------------
# Runtime stage — same digest-pinned base shape as before the source-build
# conversion, but apk-installs only the shared libraries the built binary
# links (the apk package's so: depends), not the keepalived package.
# ---------------------------------------------------------------------------
FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS base

# No apk version pin: the digest-pinned base fixes the Alpine release line, so a
# package-revision pin only strands the build on an Alpine release bump.
# apk upgrade first: the pinned base ships some packages (e.g. libssl3) stale;
# upgrading floats them forward on each rebuild.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        libcrypto3 \
        libmnl \
        libnftnl \
        libnl3 \
        libssl3

COPY --from=builder /out/usr/sbin/keepalived /usr/sbin/keepalived
# genhash (the HTTP_GET checker digest helper) is the same binary in genhash
# mode; ship the same symlink the Alpine package installs.
RUN ln -s ../sbin/keepalived /usr/bin/genhash

# ---------------------------------------------------------------------------
# Test stage — runs the build-time smoke test (binary runs at the pinned
# version with the parity feature set + config parses).
# A failure here fails the centralized `ci / validate` docker build gate,
# because the final stage below depends on this stage's marker.
# ---------------------------------------------------------------------------
FROM base AS test
ARG KEEPALIVED_VERSION
COPY tests/ /tmp/tests/
# ${KEEPALIVED_VERSION:?} fails the build if the ARG wiring ever breaks, so
# the smoke test's exact-version assertion can never be skipped in-image.
RUN KEEPALIVED_EXPECTED_VERSION="${KEEPALIVED_VERSION:?}" sh /tmp/tests/smoke.sh \
    && [ -x /usr/bin/genhash ] \
    && touch /tests-passed

# ---------------------------------------------------------------------------
# Final stage — the runtime image. Must remain last so the CI build gate
# (which builds the default target) produces it; the marker COPY forces the
# test stage to build and pass first.
# ---------------------------------------------------------------------------
FROM base AS final
COPY --from=test /tests-passed /tests-passed

# Liveness only: proves the process exists, NOT that VRRP is
# advertising. A stuck/wedged daemon still reports healthy. Watch
# docker logs (VRRP state transitions, VRRP_Script lines) or the
# SIGUSR2 stats dump for stuck-VRRP detection. See README "Healthcheck".
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof keepalived >/dev/null || exit 1
ENTRYPOINT ["keepalived", "--dont-fork", "--log-console", "--log-detail"]
