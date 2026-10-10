# shellcheck shell=bash
# Claude Code adapter: connect a user's Claude Code to the shared stack.
# The managed settings of the host give the gateway, the personal key and
# the model catalog. Managed settings win over the settings of the user.

CLAUDE_MANAGED=${CLAUDE_MANAGED:-/etc/claude-code/managed-settings.json}

harness_claude_label() { echo "Claude Code"; }
harness_claude_command() { echo claude; }

# The gateway API of Claude Code: Anthropic messages.
harness_claude_api() { echo messages; }
harness_claude_api_routes() { printf '%s\n' /v1/messages /v1/messages/count_tokens; }
harness_claude_routes() {
  echo '["/models","/v1/models","/messages","/v1/messages","/v1/messages/count_tokens","/user/daily/activity"]'
}

# The settings that onbehalf writes. The team must not set them.
harness_claude_validate() {
  local cfg="$1/claude/managed-settings.json"
  [ -e "$1/models.json" ] || die "Claude Code needs models.json as the model catalog of the stack source"
  [ ! -e "$1/claude/CLAUDE.md" ] || die "put the harness instructions of Claude Code in AGENTS.md, not in claude/CLAUDE.md"
  [ ! -e "$cfg" ] || jq -e '
    type == "object" and (has("model") or has("apiKeyHelper") or has("availableModels") | not) and
    (.env // {} | type == "object" and all(keys[]; test("^(ANTHROPIC_|CLAUDE_CODE_USE_)") | not))
  ' "$cfg" >/dev/null 2>&1 \
    || die "claude/managed-settings.json must be a JSON object without model, apiKeyHelper, availableModels and env.ANTHROPIC_*. onbehalf writes them from models.json"
}

# Write the managed settings of the release from models.json. The default
# model is the model of the aliases, so a personal "model" still wins.
harness_claude_build() {
  local cfg="$1/claude/managed-settings.json" tmp
  tmp=$(mktemp)
  { cat "$cfg" 2>/dev/null || echo '{}'; } | jq --slurpfile c "$1/models.json" --arg url "$ONBEHALF_GATEWAY_URL" '
    $c[0] as $c | ($c.model // ($c.models | keys_unsorted[0])) as $d |
    .apiKeyHelper = "cat \"$HOME/.config/onbehalf/gateway.key\"" |
    .availableModels = [$c.models | keys_unsorted[]] |
    .env = (.env // {}) + {ANTHROPIC_BASE_URL: $url, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
      ANTHROPIC_DEFAULT_OPUS_MODEL: $d, ANTHROPIC_DEFAULT_SONNET_MODEL: $d, ANTHROPIC_DEFAULT_HAIKU_MODEL: $d}
  ' >"$tmp" || die "could not write the Claude Code configuration of the model catalog"
  mv "$tmp" "$cfg"
}

# Link the managed settings of the host to the current release. The link
# follows each later release.
harness_claude_activate() {
  local want="$ONBEHALF_STACK/current/claude/managed-settings.json"
  if [ -e "$CLAUDE_MANAGED" ] && [ "$(link_of "$CLAUDE_MANAGED")" != "$want" ]; then
    die "$CLAUDE_MANAGED is not from onbehalf. Move its settings into claude/managed-settings.json of the stack source, remove the file, then install the stack again"
  fi
  install -d -m 0755 "${CLAUDE_MANAGED%/*}"
  ln -sfn "$want" "$CLAUDE_MANAGED"
  ok "Claude Code uses the managed settings of the shared stack"
}

harness_claude_stack_problem() {
  [ "$(link_of "$CLAUDE_MANAGED")" != "$ONBEHALF_STACK/current/claude/managed-settings.json" ] || return 0
  echo "Claude Code does not use the managed settings of the shared stack ($CLAUDE_MANAGED): it does not use the gateway and the model catalog"
  echo "sudo onbehalf stack install DIR"
}

# There is no service. Each new session reads the shared stack.
harness_claude_service() { return 1; }
harness_claude_runs() { pgrep -u "$1" -x claude >/dev/null; }
harness_claude_stop() { pkill -u "$1" -x claude 2>/dev/null || true; }
harness_claude_operator_runs() { pgrep -u "$1" -x claude >/dev/null 2>&1; }
harness_claude_operator_stop() { echo "/exit in each Claude Code session"; }
harness_claude_user_remove() { :; }

harness_claude_user_add() {
  harness_claude_link "$@"
  if [ "$(link_of "$2/.claude/CLAUDE.md")" = "$ONBEHALF_STACK/current/claude/AGENTS.md" ]; then
    ok "Claude Code has the shared harness instructions"
  fi
}

harness_claude_stack_changed() { harness_claude_link "$1" "$2" "$3" no; }

# Link the harness instructions, and each skill, custom agent and command of
# the shared stack, into ~/.claude. The directory stays personal: Claude
# Code keeps its state and the personal settings.json there.
harness_claude_link() {
  local u=$1 home=$2 group=$3 replace=$4
  local dir="$home/.claude" src="$ONBEHALF_STACK/current/claude" d
  install -d -o "$u" -g "$group" -m 0700 "$dir"
  [ ! -e "$src/AGENTS.md" ] || harness_link_item "$u" "$group" "$replace" "$src/AGENTS.md" "$dir/CLAUDE.md"
  for d in agents commands skills; do
    [ ! -d "$src/$d" ] || harness_link_each "$u" "$group" "$replace" "$src/$d" "$dir/$d" \
      || info "$u uses the personal $d, not the shared $d"
  done
  harness_unlink_removed "$dir" "$src"
}

# Checks for onbehalf doctor (as root) and onbehalf status (as the user).
harness_claude_check() {
  local u=$1 home=$2
  local link="$home/.claude/CLAUDE.md" want="$ONBEHALF_STACK/current/claude/AGENTS.md"
  if [ "$(link_of "$CLAUDE_MANAGED")" = "$ONBEHALF_STACK/current/claude/managed-settings.json" ]; then
    ok "Claude Code uses the shared stack"
  else
    err "Claude Code does not use the managed settings of the shared stack"
    fix "sudo onbehalf stack install DIR   (an operator)"
  fi
  if [ -e "$want" ] && [ "$(link_of "$link")" != "$want" ]; then
    warn "Claude Code does not use the shared harness instructions ($link is personal or missing)"
    if [ "$(id -u)" = 0 ]; then fix "sudo onbehalf user add --replace-config $u"; else fix "ln -sfn $want $link"; fi
  fi
  # Personal model credentials let the user bypass the gateway.
  if [ -s "$home/.claude/.credentials.json" ]; then
    warn "personal model credentials in ~/.claude/.credentials.json go around the gateway"
    fix "rm ~/.claude/.credentials.json   (as $u)"
  fi
}
