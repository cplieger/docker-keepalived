# check=error=true

# Renovate bumps KEEPALIVED_VERSION via the org-wide Dockerfile ARG
# customManager (github-tags). KEEPALIVED_SHA256 pins the upstream dist
# tarball; github-tags exposes the git sha, not the tarball hash, so the
# marker below drives the repin postUpgradeTask, which recomputes the hash
# in the same commit as the version bump. A mismatch fail-closes the build.
# renovate: datasource=github-tags depName=acassen/keepalived
ARG KEEPALIVED_VERSION=v2.4.3
# repin: dep=acassen/keepalived url=https://www.keepalived.org/software/keepalived-{version_nov}.tar.gz
ARG KEEPALIVED_SHA256=a0faef8e401c143487b131b526df7541c1e33d9b8814642fa9dfe8bb250a9632

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
# Embedded SBOM fragment. Syft inventories the final image from Alpine's APK
# database only, so the source-built keepalived binary is invisible to the
# signed release SBOM and to vulnerability scanners. Generate a CycloneDX
# fragment from the same Renovate-tracked version ARG the build uses — a
# Renovate bump keeps the SBOM correct with zero extra maintenance — and
# ship it in the runtime image where Syft's sbom-cataloger picks it up. The
# cataloger is enabled centrally by the release pipeline (cplieger/ci); no
# per-repo .syft.yaml is needed.
# purl: pkg:generic with the real provenance (the keepalived.org dist
# tarball fetched above, not a forge archive), download_url + checksum
# qualifiers mirroring the fetch. CPE vendor:product is
# keepalived:keepalived per the NVD CPE dictionary, e.g.
# https://nvd.nist.gov/products/cpe/detail/B6CF2665-405B-4810-BB6D-9088CFD1868C/
# ---------------------------------------------------------------------------
RUN cat > /out/keepalived.cdx.json <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "components": [
    {
      "bom-ref": "pkg:generic/keepalived@${KEEPALIVED_VERSION#v}",
      "type": "application",
      "name": "keepalived",
      "version": "${KEEPALIVED_VERSION#v}",
      "purl": "pkg:generic/keepalived@${KEEPALIVED_VERSION#v}?download_url=https://www.keepalived.org/software/keepalived-${KEEPALIVED_VERSION#v}.tar.gz&checksum=sha256:${KEEPALIVED_SHA256}",
      "cpe": "cpe:2.3:a:keepalived:keepalived:${KEEPALIVED_VERSION#v}:*:*:*:*:*:*:*"
    }
  ]
}
EOF

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
# PKG_REFRESH busts the cache for this layer. Without it BuildKit restores the
# layer verbatim on every rebuild, so the `apk upgrade` below floats nothing
# forward after the first build and the image keeps shipping the packages that
# were current then. The central release/CI/scan builds pass today's UTC date.
# The `echo` is load-bearing: BuildKit keys a RUN on the build args it actually
# CONSUMES, so a merely-declared ARG would change nothing.
ARG PKG_REFRESH=static
RUN echo "OS package refresh: ${PKG_REFRESH}" \
    && apk upgrade --no-cache \
    && apk add --no-cache \
        libcrypto3 \
        libmnl \
        libnftnl \
        libnl3 \
        libssl3

COPY --from=builder /out/usr/sbin/keepalived /usr/sbin/keepalived
# CycloneDX SBOM fragment for the source-built keepalived (generated in the
# builder stage from the Renovate-tracked version ARG). Placed where the
# release pipeline's Syft sbom-cataloger inventories it, so SBOMs and
# scanners see keepalived alongside the APK packages.
COPY --from=builder /out/keepalived.cdx.json /usr/share/sbom/keepalived.cdx.json
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
    CMD ["pidof", "keepalived"]
ENTRYPOINT ["keepalived", "--dont-fork", "--log-console", "--log-detail"]
