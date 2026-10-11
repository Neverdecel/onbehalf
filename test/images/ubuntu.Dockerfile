# syntax=docker/dockerfile:1
# Clean Ubuntu host with only the prerequisites. onbehalf itself is installed
# by the tests, so every run starts from this state.
FROM ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55

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
