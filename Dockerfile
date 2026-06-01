# check=error=true

FROM alpine:3.23.4@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11

# renovate: datasource=repology depName=alpine_3_23/keepalived versioning=loose
ARG KEEPALIVED_VERSION=2.3.4-r3

RUN apk add --no-cache \
        keepalived="${KEEPALIVED_VERSION}"

COPY --chmod=755 check_caddy.sh check_netbird.sh check_netbird_relay.sh check_wgeasy.sh notify.sh /usr/local/bin/

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof keepalived >/dev/null || exit 1
ENTRYPOINT ["keepalived", "--dont-fork", "--log-console", "--log-detail"]
