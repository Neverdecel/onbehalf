#!/usr/bin/env bash
# Test setup: a host with onbehalf installed and two users, made with the
# same commands an operator uses. Runs once per test run, before the checks.
set -euo pipefail

/src/install.sh
printf %s "${LITELLM_MASTER_KEY:?}" | onbehalf init --gateway-url "${ONBEHALF_GATEWAY_URL:?}"
onbehalf stack install /src/test/stack
onbehalf user add alice bob
/src/test/fixtures/forgejo-setup.sh alice bob
