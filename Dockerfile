# check=error=true

FROM alpine:3.24.0@sha256:660e0827bd401543d81323d4886abbd08fda0fe3ba84337837d0b11a67251283

# renovate: datasource=repology depName=alpine_3_23/keepalived versioning=loose
ARG KEEPALIVED_VERSION=2.3.4-r3

RUN apk add --no-cache \
        keepalived="${KEEPALIVED_VERSION}"

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof keepalived >/dev/null || exit 1
ENTRYPOINT ["keepalived", "--dont-fork", "--log-console", "--log-detail"]
