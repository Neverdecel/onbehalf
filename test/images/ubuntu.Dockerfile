# syntax=docker/dockerfile:1
# Clean Ubuntu host with only the prerequisites. onbehalf itself is installed
# by the tests, so every run starts from this state.
FROM ubuntu:24.04@sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac

# Keep downloaded packages in the BuildKit cache mount between builds.
# Optionally use another package mirror, for example the CI provider's.
ARG UBUNTU_MIRROR
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && if [ -n "$UBUNTU_MIRROR" ]; then \
      sed -i "s|http://archive.ubuntu.com/ubuntu/\?|$UBUNTU_MIRROR|" /etc/apt/sources.list.d/ubuntu.sources; \
    fi
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash bats ca-certificates curl git iproute2 jq nodejs npm procps sudo util-linux

# System-wide OpenCode, pinned by hash in opencode/package-lock.json.
COPY opencode/package.json opencode/package-lock.json /opt/opencode/
RUN --mount=type=cache,target=/root/.npm \
    npm ci --prefix /opt/opencode --omit=dev \
    && ln -s /opt/opencode/node_modules/.bin/opencode /usr/local/bin/opencode

# System-wide Claude Code for the checks of the Claude Code adapter, pinned
# by hash in claude/package-lock.json. Only the Ubuntu host has it.
COPY claude/package.json claude/package-lock.json /opt/claude/
RUN --mount=type=cache,target=/root/.npm \
    npm ci --prefix /opt/claude --omit=dev \
    && ln -s /opt/claude/node_modules/.bin/claude /usr/local/bin/claude

# System-wide Codex for the checks of the Codex adapter, pinned by hash in
# codex/package-lock.json. Only the Ubuntu host has it.
COPY codex/package.json codex/package-lock.json /opt/codex/
RUN --mount=type=cache,target=/root/.npm \
    npm ci --prefix /opt/codex --omit=dev \
    && ln -s /opt/codex/node_modules/.bin/codex /usr/local/bin/codex

# The OTel Collector for the checks of onbehalf telemetry, from the official
# image, pinned by digest. The otelcol-contrib package makes the same group.
# Only the Ubuntu host has it.
COPY --from=otel/opentelemetry-collector-contrib:0.161.0@sha256:fd328de2552466ad78385e1b1289c3f2402b1c45f265b252aab1955b42845ac1 \
    /otelcol-contrib /usr/local/bin/otelcol-contrib
RUN groupadd --system otelcol-contrib \
    && useradd --system -g otelcol-contrib -d /nonexistent -s /usr/sbin/nologin otelcol-contrib
