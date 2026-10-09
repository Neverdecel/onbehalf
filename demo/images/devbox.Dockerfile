# syntax=docker/dockerfile:1
# Demo host: the clean test host with an SSH server and a sudo operator "ops".
# onbehalf is not installed: the operator cast installs it.
# Built from test/images/ubuntu.Dockerfile (profile "base" in compose.yaml).
# hadolint ignore=DL3006
FROM onbehalf-test/host-ubuntu

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server

COPY fixtures/gh.sh /usr/local/bin/gh
COPY fixtures/az.sh /usr/local/bin/az
COPY entrypoint.sh /usr/local/sbin/demo-entrypoint
RUN userdel -r ubuntu \
    && useradd -m -s /bin/bash -G sudo -c "Host operator" ops \
    && echo 'ops ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/ops \
    && touch /home/ops/.sudo_as_admin_successful \
    && chown ops:ops /home/ops/.sudo_as_admin_successful \
    && rm -f /etc/update-motd.d/* /etc/legal \
    && printf '%s\n' 'AuthorizedKeysFile /demo-keys/authorized_keys' 'PasswordAuthentication no' \
      'PrintMotd no' 'PrintLastLog no' >/etc/ssh/sshd_config.d/demo.conf

ENTRYPOINT ["/usr/local/sbin/demo-entrypoint"]
