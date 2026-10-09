# syntax=docker/dockerfile:1
# VHS, to record the casts, with an SSH client to reach devbox.
FROM ghcr.io/charmbracelet/vhs:v0.10.0@sha256:e88ed3faa06183a197fd44ded83e706098d9e4038b72da94bcdb9cb9b67e3527

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-client \
    && mkdir -p /root/.ssh \
    && printf '%s\n' 'Host devbox' '  IdentityFile /demo-keys/id_ed25519' '  StrictHostKeyChecking no' \
      '  UserKnownHostsFile /dev/null' '  LogLevel ERROR' >/root/.ssh/config
