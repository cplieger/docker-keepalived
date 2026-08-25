# check=error=true

# renovate: datasource=github-tags depName=acassen/keepalived
ARG KEEPALIVED_VERSION=v2.4.3
# repin: dep=acassen/keepalived url=https://www.keepalived.org/software/keepalived-{version_nov}.tar.gz
ARG KEEPALIVED_SHA256=a0faef8e401c143487b131b526df7541c1e33d9b8814642fa9dfe8bb250a9632

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS builder

SHELL ["/bin/ash", "-eo", "pipefail", "-c"]

RUN apk add --no-cache \
        build-base \
        curl \
        libmnl-dev \
        libnftnl-dev \
        libnl3-dev \
        linux-headers \
        openssl-dev \
        pkgconf

ARG KEEPALIVED_VERSION
ARG KEEPALIVED_SHA256

WORKDIR /build/keepalived
# --enable-nftables turns missing nftables headers into a configure error
# rather than a silent feature drop; missing libnftnl/libmnl only warn, so
# tests/smoke.sh's Config-options assertion is what catches those.
# Syft's catalogers do not identify this source-built keepalived, so the
# image carries a CycloneDX fragment for it; the release pipeline's
# sbom-cataloger discovers the fragment by its .cdx.json suffix, not by
# this path.
RUN url="https://www.keepalived.org/software/keepalived-${KEEPALIVED_VERSION#v}.tar.gz" \
    && tarball="${url##*/}" \
    && curl -fsSL --connect-timeout 10 --max-time 120 --retry 7 --retry-max-time 150 --retry-all-errors -o "$tarball" "$url" \
    && echo "${KEEPALIVED_SHA256}  ${tarball}" | sha256sum -c - \
    && tar xzf "$tarball" --strip-components=1 --no-same-owner \
    && rm "$tarball" \
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
    && cat > /out/keepalived.cdx.json <<EOF
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
      "purl": "pkg:generic/keepalived@${KEEPALIVED_VERSION#v}?download_url=${url}&checksum=sha256:${KEEPALIVED_SHA256}",
      "cpe": "cpe:2.3:a:keepalived:keepalived:${KEEPALIVED_VERSION#v}:*:*:*:*:*:*:*"
    }
  ]
}
EOF

FROM alpine:3.24.1@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b AS base

# The `echo` is load-bearing: BuildKit keys a RUN on the args it CONSUMES, so a
# merely-declared PKG_REFRESH would not bust this layer's cache.
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
COPY --from=builder /out/keepalived.cdx.json /usr/share/sbom/keepalived.cdx.json
# keepalived runs in genhash mode when it is invoked as genhash (argv[0]).
RUN ln -s ../sbin/keepalived /usr/bin/genhash

FROM base AS test
ARG KEEPALIVED_VERSION
RUN apk add --no-cache jq
COPY tests/ /tmp/tests/
# ${KEEPALIVED_VERSION:?} fails the build if the ARG wiring ever breaks, so
# the smoke test's exact-version assertion can never be skipped in-image.
RUN KEEPALIVED_EXPECTED_VERSION="${KEEPALIVED_VERSION:?}" sh /tmp/tests/smoke.sh \
    && touch /tests-passed

# Final stage — must stay last (the CI gate builds the default target); the
# marker COPY is what forces the test stage to build and pass first.
FROM base AS final
COPY --from=test /tests-passed /tests-passed

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD ["pidof", "keepalived"]
ENTRYPOINT ["keepalived", "--dont-fork", "--log-console", "--log-detail"]
