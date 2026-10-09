# syntax=docker/dockerfile:1
# Clean Arch host with only the prerequisites. onbehalf itself is installed
# by the tests, so every run starts from this state.
FROM archlinux:base@sha256:4e77cf2ea5f410e6f8be5abf93ccf17ce2436e87a138c167208356711a405dbd

RUN --mount=type=cache,target=/var/cache/pacman/pkg \
    pacman -Syu --noconfirm --needed \
      bash bats ca-certificates curl git iproute2 jq nodejs npm procps-ng sudo util-linux

# System-wide OpenCode, pinned by hash in opencode/package-lock.json.
COPY opencode/package.json opencode/package-lock.json /opt/opencode/
RUN --mount=type=cache,target=/root/.npm \
    npm ci --prefix /opt/opencode --omit=dev \
    && ln -s /opt/opencode/node_modules/.bin/opencode /usr/local/bin/opencode
