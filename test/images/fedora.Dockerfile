# syntax=docker/dockerfile:1
# Clean Fedora host with only the prerequisites. onbehalf itself is installed
# by the tests, so every run starts from this state.
FROM fedora:44@sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80

RUN dnf install -y --setopt=install_weak_deps=False \
      bash bats ca-certificates curl git iproute jq nodejs npm procps-ng sudo util-linux \
    && dnf clean all

# System-wide OpenCode, pinned by hash in opencode/package-lock.json.
COPY opencode/package.json opencode/package-lock.json /opt/opencode/
RUN --mount=type=cache,target=/root/.npm \
    npm ci --prefix /opt/opencode --omit=dev \
    && ln -s /opt/opencode/node_modules/.bin/opencode /usr/local/bin/opencode
