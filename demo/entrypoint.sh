#!/usr/bin/env bash
# Starts devbox: one SSH key for all demo accounts, a copy of the onbehalf
# source for the operator, then the SSH server.
set -euo pipefail

if [ ! -e /demo-keys/id_ed25519 ]; then
  ssh-keygen -q -t ed25519 -N '' -C demo -f /demo-keys/id_ed25519
fi
install -m 0644 /demo-keys/id_ed25519.pub /demo-keys/authorized_keys

# The operator starts from a checkout of onbehalf.
cp -r /src /home/ops/onbehalf
rm -rf /home/ops/onbehalf/.git /home/ops/onbehalf/site/_site
chown -R ops:ops /home/ops/onbehalf

# The admin key of the demo gateway (compose.yaml), for onbehalf init.
install -o ops -g ops -m 0600 /dev/null /home/ops/admin.key
echo sk-demo-admin-key >/home/ops/admin.key

mkdir -p /run/sshd
exec /usr/sbin/sshd -D -e
