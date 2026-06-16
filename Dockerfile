# check=error=true

FROM alpine:3.24.1@sha256:bec4ccd3817e7c824eb0388971a0b83fab111d586285511ba0266b77e8dc65a9 AS base

# No apk version pin: the digest-pinned base fixes the Alpine release line, so a
# package-revision pin only strands the build on an Alpine release bump.
# apk upgrade first: the pinned base ships some packages (e.g. libssl3) stale;
# upgrading floats them forward on each rebuild.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
        keepalived

# ---------------------------------------------------------------------------
# Test stage — runs the build-time smoke test (binary runs + config parses).
# A failure here fails the centralized `ci / validate` docker build gate,
# because the final stage below depends on this stage's marker.
# ---------------------------------------------------------------------------
FROM base AS test
COPY tests/ /tmp/tests/
RUN sh /tmp/tests/smoke.sh && touch /tests-passed

# ---------------------------------------------------------------------------
# Final stage — the runtime image. Must remain last so the CI build gate
# (which builds the default target) produces it; the marker COPY forces the
# test stage to build and pass first.
# ---------------------------------------------------------------------------
FROM base AS final
COPY --from=test /tests-passed /tests-passed

HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=15s \
    CMD pidof keepalived >/dev/null || exit 1
ENTRYPOINT ["keepalived", "--dont-fork", "--log-console", "--log-detail"]
