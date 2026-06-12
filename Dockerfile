# check=error=true

FROM alpine:3.24.0@sha256:a2d49ea686c2adfe3c992e47dc3b5e7fa6e6b5055609400dc2acaeb241c829f4

# No apk version pin: the digest-pinned base fixes the Alpine release line, so a
# package-revision pin only strands the build on an Alpine release bump.
RUN apk add --no-cache --upgrade \
        keepalived

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof keepalived >/dev/null || exit 1
ENTRYPOINT ["keepalived", "--dont-fork", "--log-console", "--log-detail"]
