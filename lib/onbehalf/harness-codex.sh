# shellcheck shell=bash
# Codex adapter: connect a user's Codex to the shared stack. The system
# configuration of the host gives the gateway, the personal key and the
# default model. The configuration of the user wins over it.

CODEX_CONFIG=${CODEX_CONFIG:-/etc/codex/config.toml}

harness_codex_label() { echo Codex; }
harness_codex_command() { echo codex; }

# The gateway API of Codex: responses.
harness_codex_api() { echo responses; }
harness_codex_api_routes() { echo /v1/responses; }
harness_codex_routes() {
  echo '["/models","/v1/models","/responses","/v1/responses","/user/daily/activity"]'
}

# The settings that onbehalf writes. The team must not set them.
harness_codex_validate() {
  local cfg="$1/codex/config.toml"
  [ -e "$1/models.json" ] || die "Codex needs models.json as the model catalog of the stack source"
  # The keys of the root table are the lines before the first table.
  if [ -e "$cfg" ] && { sed '/^[[:space:]]*\[/,$d' "$cfg" | grep -Eq '^[[:space:]]*"?(model|model_provider)"?[[:space:]]*=' \
    || grep -Eq '^[[:space:]]*\[+[[:space:]]*model_providers[[:space:]]*\.[[:space:]]*"?onbehalf"?[].[:space:]]' "$cfg"; }; then
    die "codex/config.toml must not have model, model_provider and the provider onbehalf. onbehalf writes them from models.json"
  fi
}

# Write the system configuration of the release from models.json. The keys
# of onbehalf go before the settings of the team, because a TOML file has
# its root keys before the first table. The provider goes after them.
harness_codex_build() {
  local cfg="$1/codex/config.toml" tmp
  tmp=$(mktemp)
  {
    printf 'model = "%s"\nmodel_provider = "onbehalf"\n\n' "$(stack_default_model "$1")"
    cat "$cfg" 2>/dev/null || true
    printf '\n[model_providers.onbehalf]\nname = "Team models"\nbase_url = "%s/v1"\nwire_api = "responses"\n' "$ONBEHALF_GATEWAY_URL"
    # The key command runs as the user, so $HOME is the home of the user.
    printf '\n[model_providers.onbehalf.auth]\ncommand = "sh"\nargs = ["-c", %s]\n' \
      \''cat "$HOME/.config/onbehalf/gateway.key"'\'
  } >"$tmp" || die "could not write the Codex configuration of the model catalog"
  mv "$tmp" "$cfg"
  chmod 0644 "$cfg"
}

# Link the system configuration of the host to the current release. The
# link follows each later release.
harness_codex_activate() {
  local want="$ONBEHALF_STACK/current/codex/config.toml"
  if [ -e "$CODEX_CONFIG" ] && [ "$(link_of "$CODEX_CONFIG")" != "$want" ]; then
    die "$CODEX_CONFIG is not from onbehalf. Move its settings into codex/config.toml of the stack source, remove the file, then install the stack again"
  fi
  install -d -m 0755 "${CODEX_CONFIG%/*}"
  ln -sfn "$want" "$CODEX_CONFIG"
  ok "Codex uses the system configuration of the shared stack"
}

harness_codex_deactivate() {
  [ "$(link_of "$CODEX_CONFIG")" != "$ONBEHALF_STACK/current/codex/config.toml" ] || rm -f "$CODEX_CONFIG"
}
harness_codex_user_unlink() { harness_unlink_all "$1/.codex" "$ONBEHALF_STACK/current/codex"; }

harness_codex_stack_problem() {
  [ "$(link_of "$CODEX_CONFIG")" != "$ONBEHALF_STACK/current/codex/config.toml" ] || return 0
  echo "Codex does not use the system configuration of the shared stack ($CODEX_CONFIG): it does not use the gateway"
  echo "sudo onbehalf stack install DIR"
}

# There is no service. Each new session reads the shared stack.
harness_codex_service() { return 1; }
harness_codex_runs() { pgrep -u "$1" -x codex >/dev/null; }
harness_codex_stop() { pkill -u "$1" -x codex 2>/dev/null || true; }
harness_codex_operator_runs() { pgrep -u "$1" -x codex >/dev/null 2>&1; }
harness_codex_operator_stop() { echo "/quit in each Codex session"; }
harness_codex_user_remove() { :; }

harness_codex_user_add() {
  harness_codex_link "$@"
  if [ "$(link_of "$2/.codex/AGENTS.md")" = "$ONBEHALF_STACK/current/codex/AGENTS.md" ]; then
    ok "Codex has the shared harness instructions"
  fi
}

harness_codex_stack_changed() { harness_codex_link "$1" "$2" "$3" no; }

# Link the harness instructions and each skill of the shared stack into
# ~/.codex. The directory stays personal: Codex keeps its state and the
# personal config.toml there.
harness_codex_link() {
  local u=$1 home=$2 group=$3 replace=$4
  local dir="$home/.codex" src="$ONBEHALF_STACK/current/codex"
  install -d -o "$u" -g "$group" -m 0700 "$dir"
  [ ! -e "$src/AGENTS.md" ] || harness_link_item "$u" "$group" "$replace" "$src/AGENTS.md" "$dir/AGENTS.md"
  [ ! -d "$src/skills" ] || harness_link_each "$u" "$group" "$replace" "$src/skills" "$dir/skills" \
    || info "$u uses the personal skills, not the shared skills"
  harness_unlink_removed "$dir" "$src"
}

# Checks for onbehalf doctor (as root) and onbehalf status (as the user).
harness_codex_check() {
  local u=$1 home=$2
  local link="$home/.codex/AGENTS.md" want="$ONBEHALF_STACK/current/codex/AGENTS.md"
  if [ "$(link_of "$CODEX_CONFIG")" = "$ONBEHALF_STACK/current/codex/config.toml" ]; then
    ok "Codex uses the shared stack"
  else
    err "Codex does not use the system configuration of the shared stack"
    fix "sudo onbehalf stack install DIR   (an operator)"
  fi
  if [ -e "$want" ] && [ "$(link_of "$link")" != "$want" ]; then
    warn "Codex does not use the shared harness instructions ($link is personal or missing)"
    if [ "$(id -u)" = 0 ]; then fix "sudo onbehalf user add --replace-config $u"; else fix "ln -sfn $want $link"; fi
  fi
  # Personal model credentials let the user bypass the gateway.
  if [ -s "$home/.codex/auth.json" ]; then
    warn "personal model credentials in ~/.codex/auth.json go around the gateway"
    fix "codex logout   (as $u), or remove the file"
  fi
}
