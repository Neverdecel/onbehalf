#!/usr/bin/env bash
# Install on a host that is already in use: carol has an account, her own
# OpenCode config and her own model credentials. onbehalf must not destroy
# her config. Native JSONC overrides preserve her settings and shared defaults.
set -uo pipefail
. /src/test/lib.sh

useradd -m -s /bin/bash carol
as carol "mkdir -p ~/.config/opencode ~/.local/share/opencode \
  && echo '{\"model\":\"onbehalf/mock-model-v2\"}' > ~/.config/opencode/opencode.json \
  && echo '{\"openai\":{\"type\":\"api\",\"key\":\"sk-personal\"}}' > ~/.local/share/opencode/auth.json"
cfg=/home/carol/.config/opencode/opencode.json
before=$(<"$cfg")

out=$(onbehalf user add carol 2>&1)
check "adding carol with a personal config succeeds" test $? -eq 0
check "carol's personal config is preserved as JSONC" test "$(cat "${cfg}c")" = "$before"
check "carol's existing account was used" grep -q "uses the existing account carol" <<<"$out"

out=$(onbehalf doctor 2>&1)
check "doctor passes with carol's personal override" test $? -eq 0

out=$(as carol "cd ~ && timeout 180 opencode run hi" 2>&1)
check "carol's override uses the shared gateway provider" grep -q onbehalf-mock-v2 <<<"$out"

# Two existing personal files are ambiguous. Do not overwrite either one.
rm "$cfg"
printf '%s' '{"model":"onbehalf/mock-model"}' >"$cfg"
out=$(onbehalf user add carol 2>&1)
check "two personal config files need an explicit decision" test $? -ne 0
check "the collision explains how to combine the files" grep -q "Put them together in opencode.jsonc" <<<"$out"
check "the JSONC override is unchanged" test "$(cat "${cfg}c")" = "$before"

out=$(onbehalf user add --replace-config carol 2>&1)
check "adding carol with --replace-config succeeds" test $? -eq 0
check "carol's config is now the shared stack" \
  test "$(readlink "$cfg")" = "$ONBEHALF_STACK/current/opencode/opencode.json"
check "carol's old JSON is kept as a backup" test "$(cat "$cfg.before-onbehalf")" = '{"model":"onbehalf/mock-model"}'
check "replace-config preserves her JSONC override" test "$(cat "${cfg}c")" = "$before"

out=$(onbehalf doctor 2>&1)
check "doctor passes with carol on the shared stack" test $? -eq 0
check "doctor warns that carol's own model credentials bypass the gateway" grep -q "go around the gateway" <<<"$out"

out=$(as carol "cd ~ && timeout 180 opencode run hi" 2>&1)
check "carol's agent answers through the gateway" grep -q onbehalf-mock-v2 <<<"$out"

onbehalf user remove carol >/dev/null 2>&1
check "carol is removed again (test cleanup)" bash -c '! id carol >/dev/null 2>&1'

exit $FAILED
