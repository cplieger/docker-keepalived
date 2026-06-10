# check=error=true

FROM alpine:3.24.0@sha256:8ddefa941e689fc29abcdeb8dae3b3c6d139cc08ce9a52633931160701770685

# renovate: datasource=repology depName=alpine_3_23/keepalived versioning=loose
ARG KEEPALIVED_VERSION=2.3.4-r3

RUN apk add --no-cache \
        keepalived="${KEEPALIVED_VERSION}"

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof keepalived >/dev/null || exit 1
ENTRYPOINT ["keepalived", "--dont-fork", "--log-console", "--log-detail"]
