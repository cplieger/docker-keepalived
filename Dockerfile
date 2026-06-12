# check=error=true

FROM alpine:3.24.0@sha256:a2d49ea686c2adfe3c992e47dc3b5e7fa6e6b5055609400dc2acaeb241c829f4

# renovate: datasource=repology depName=alpine_3_24/keepalived versioning=loose
ARG KEEPALIVED_VERSION=2.3.4-r3

RUN apk add --no-cache \
        keepalived="${KEEPALIVED_VERSION}"

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof keepalived >/dev/null || exit 1
ENTRYPOINT ["keepalived", "--dont-fork", "--log-console", "--log-detail"]
