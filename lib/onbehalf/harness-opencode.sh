# shellcheck shell=bash
# OpenCode adapter: connect a user's OpenCode to the shared stack.

harness_opencode_user_add() {
  local u=$1 home=$2 group=$3 replace=$4
  harness_opencode_link "$u" "$home" "$group" "$replace"
  # OpenCode 2.x uses one fixed service port by default; give each user their own.
  harness_opencode_port_assign "$u"
  as_user "$u" "opencode service set port $(harness_opencode_port "$u")" >/dev/null
  ok "OpenCode has its own service port $(harness_opencode_port "$u")"
  if [ "$(link_of "$home/.config/opencode/opencode.json")" = "$ONBEHALF_STACK/current/opencode/opencode.json" ]; then
    ok "OpenCode uses the shared stack"
  fi
}

# The port is PORT_BASE + uid. Directory accounts (Entra login) have large
# uids that do not fit; they get a free port from the list in PORTS_FILE.
PORTS_FILE=${PORTS_FILE:-$ONBEHALF_ETC/ports} # lines: NAME PORT
harness_opencode_port() {
  local p=$((ONBEHALF_PORT_BASE + $(id -u "$1")))
  if [ "$p" -le 65535 ]; then
    echo "$p"
  else
    [ -r "$PORTS_FILE" ] && awk -v n="$1" '$1 == n { print $2 }' "$PORTS_FILE" || true
  fi
}

harness_opencode_port_assign() {
  local u=$1 p used tmp
  [ -z "$(harness_opencode_port "$u")" ] || return 0
  # Ports in use: the list, and the ports of users with a small uid.
  used=" $(awk '{ print $2 }' "$PORTS_FILE" 2>/dev/null | tr '\n' ' ')"
  for p in $(people); do used="$used$((ONBEHALF_PORT_BASE + $(id -u "$p"))) "; done
  for ((p = 65535; p > ONBEHALF_PORT_BASE; p--)); do
    case $used in *" $p "*) continue ;; esac
    tmp=$(mktemp "$PORTS_FILE.XXXXXX")
    {
      cat "$PORTS_FILE" 2>/dev/null || true
      echo "$u $p"
    } >"$tmp"
    chmod 0644 "$tmp"
    mv "$tmp" "$PORTS_FILE"
    return 0
  done
  die "no free OpenCode service port for $u"
}

harness_opencode_port_release() {
  [ -r "$PORTS_FILE" ] || return 0
  local tmp
  tmp=$(mktemp "$PORTS_FILE.XXXXXX")
  awk -v n="$1" '$1 != n' "$PORTS_FILE" >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$PORTS_FILE"
}

# Called for every user after the current stack changed.
harness_opencode_stack_changed() {
  local u=$1 home=$2 group=$3 restart=$4
  harness_opencode_link "$u" "$home" "$group" no
  # A running service keeps the config it started with.
  if [ "$restart" = yes ] && pgrep -u "$u" -f 'serve --service' >/dev/null; then
    as_user "$u" "opencode service restart" >/dev/null
    ok "restarted the OpenCode service of $u"
  fi
}

# Link every item of the shared stack into the user's OpenCode config
# directory. The directory itself stays personal: OpenCode keeps state there.
# A personal item is kept, unless REPLACE is yes: then it moves aside.
harness_opencode_link() {
  local u=$1 home=$2 group=$3 replace=$4
  local dir="$home/.config/opencode" src="$ONBEHALF_STACK/current/opencode"
  local item name link child

  install -d -o "$u" -g "$group" -m 0700 "$dir"
  # Native V2 precedence: global JSON defaults, then personal JSONC overrides.
  # Adopt an existing JSON file without parsing or rewriting its contents.
  link="$dir/opencode.json"
  if { [ -e "$link" ] || [ -L "$link" ]; } && [ "$(link_of "$link")" != "$src/opencode.json" ] && [ "$replace" != yes ]; then
    if [ -e "$dir/opencode.jsonc" ] || [ -L "$dir/opencode.jsonc" ]; then
      err "$u has a personal opencode.json and a personal opencode.jsonc. Put them together in opencode.jsonc, then run user add again"
      return
    fi
    mv "$link" "$dir/opencode.jsonc"
    ok "kept the personal configuration as opencode.jsonc"
  fi
  for item in "$src"/*; do
    name=${item##*/}
    link="$dir/$name"
    # Named agents, skills and commands shadow individually, not as a directory.
    if [ -d "$item" ]; then
      if [ "$(link_of "$link")" = "$item" ]; then rm "$link"; fi
      if [ ! -e "$link" ]; then install -d -o "$u" -g "$group" -m 0700 "$link"; fi
      if [ -d "$link" ] && [ ! -L "$link" ]; then
        for child in "$item"/*; do
          [ -e "$child" ] || continue
          harness_opencode_item "$u" "$group" "$replace" "$child" "$link/${child##*/}"
        done
        continue
      fi
    fi
    harness_opencode_item "$u" "$group" "$replace" "$item" "$link"
  done

  # Remove only our broken links, including removed named shared items.
  while IFS= read -r -d '' link; do
    if [[ $(link_of "$link") == "$src/"* ]] && [ ! -e "$link" ]; then rm -f "$link"; fi
  done < <(find "$dir" -type l -print0)
}

harness_opencode_item() {
  local u=$1 group=$2 replace=$3 item=$4 link=$5 backup name=${5##*/}
  if { [ -e "$link" ] || [ -L "$link" ]; } && [ "$(link_of "$link")" != "$item" ]; then
    if [ "$replace" = yes ]; then
      backup="$link.before-onbehalf"
      # A skill directory backup must not remain in OpenCode's discovery tree.
      if [ -d "$link" ]; then
        backup="$(home_of "$u")/.config/onbehalf/backups/$name.before-onbehalf"
        install -d -o "$u" -g "$group" -m 0700 "${backup%/*}"
      fi
      while [ -e "$backup" ] || [ -L "$backup" ]; do backup="$backup.bak"; done
      mv "$link" "$backup"
      ok "moved the personal $name to ${backup##*/}"
    else
      info "$u uses the personal $name, not the shared item with the same name"
      return
    fi
  fi
  ln -sfn "$item" "$link"
  chown -h "$u:$group" "$link"
}

# Checks for onbehalf doctor (as root) and onbehalf status (as the user).
# A user gets fixes that they can do in their own account, without root.
# harness_opencode_check USER HOME
harness_opencode_check() {
  local u=$1 home=$2 user=no
  local dir="$home/.config/opencode"
  local cfg="$dir/opencode.json" want="$ONBEHALF_STACK/current/opencode/opencode.json"
  [ "$(id -u)" = 0 ] || user=yes

  if [ "$(link_of "$cfg")" = "$want" ]; then
    ok "OpenCode uses the shared stack"
  else
    err "OpenCode does not use the shared stack ($cfg is personal or missing)"
    if [ "$user" = no ]; then
      fix "sudo onbehalf user add --replace-config $u"
    elif [ -f "$cfg" ] && [ ! -L "$cfg" ] && [ -e "$dir/opencode.jsonc" ]; then
      fix "put the settings of $cfg into $dir/opencode.jsonc, remove $cfg, then: ln -s $want $cfg"
    elif [ -f "$cfg" ] && [ ! -L "$cfg" ]; then
      fix "mv $cfg $dir/opencode.jsonc && ln -s $want $cfg"
    else
      fix "ln -sfn $want $cfg"
    fi
  fi

  # Each user needs a service port of their own. onbehalf assigns one;
  # a user can choose a different one.
  local port want_port
  want_port=$(harness_opencode_port "$u")
  port=$(jq -r '.port // empty' "$dir/service.json" 2>/dev/null || true)
  if [ "$port" = "$want_port" ]; then
    ok "OpenCode service has its own port $port"
  elif [ -n "$port" ]; then
    info "OpenCode service uses port $port, not the assigned port $want_port"
  else
    err "OpenCode service port is the shared default, not $want_port"
    if [ "$user" = no ]; then
      fix "sudo onbehalf user add $u"
    else
      fix "opencode service set port $want_port && opencode service restart"
    fi
  fi

  # Personal model credentials let the user bypass the gateway.
  if [ -s "$home/.local/share/opencode/auth.json" ]; then
    warn "personal model credentials in ~/.local/share/opencode/auth.json go around the gateway"
    fix "opencode auth logout   (as $u), or remove the file"
  fi
}
