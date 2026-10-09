#!/bin/sh
# Start Forgejo and create the test admin once the server answers.
# The healthcheck waits for /tmp/admin-ready.
(
  until wget -qO- http://127.0.0.1:3000/api/healthz >/dev/null 2>&1; do sleep 1; done
  forgejo admin user create --admin --username root --password "$FORGEJO_ADMIN_PASSWORD" \
    --email root@onbehalf.test --must-change-password=false && touch /tmp/admin-ready
) &
exec /usr/bin/dumb-init -- /usr/local/bin/docker-entrypoint.sh
