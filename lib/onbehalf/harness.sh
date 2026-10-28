# shellcheck shell=bash
# The AI harness of the host. onbehalf supports one AI harness: OpenCode.
# The adapter, harness-opencode.sh, gives the functions harness_opencode_OP.

# harness OP [ARGS]: call OP of the OpenCode adapter. The configuration of
# a host from onbehalf 0.2 can name Claude Code or Codex.
harness() {
  local op=$1
  shift
  [ "${ONBEHALF_HARNESS:-opencode}" = opencode ] \
    || die "onbehalf supports only OpenCode. $ONBEHALF_ETC/onbehalf.conf sets ONBEHALF_HARNESS=$ONBEHALF_HARNESS. Install OpenCode for the full host, remove that line, then run: sudo onbehalf stack install DIR"
  "harness_opencode_$op" "$@"
}

# Check the OpenCode directory of a stack source. A stack source with only
# models.json, AGENTS.md and skills/ is also correct.
harness_validate() { harness_opencode_validate "$1"; }

# Build a new release directory: give the harness instructions and the
# skills at the root to OpenCode. With models.json, the adapter writes the
# model catalog into the configuration of OpenCode.
harness_build() {
  local rel=$1
  [ -d "$rel/opencode" ] || [ -e "$rel/models.json" ] || return 0
  install -d "$rel/opencode"
  [ ! -e "$rel/AGENTS.md" ] || cp "$rel/AGENTS.md" "$rel/opencode/AGENTS.md"
  if [ -d "$rel/skills" ]; then
    install -d "$rel/opencode/skills"
    cp -R "$rel/skills/." "$rel/opencode/skills/"
  fi
  [ ! -e "$rel/models.json" ] || harness_opencode_build "$rel"
}

# The link code of each adapter.

# harness_link_item USER GROUP REPLACE ITEM LINK: link one shared item. A
# personal item is kept, unless REPLACE is yes: then it moves aside.
harness_link_item() {
  local u=$1 group=$2 replace=$3 item=$4 link=$5 backup name=${5##*/}
  if { [ -e "$link" ] || [ -L "$link" ]; } && [ "$(link_of "$link")" != "$item" ]; then
    if [ "$replace" = yes ]; then
      backup="$link.before-onbehalf"
      # A skill directory backup must not remain in the discovery tree of the AI harness.
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

# harness_link_each USER GROUP REPLACE SRC DIR: link each item of the shared
# directory SRC into the personal directory DIR. Named agents, skills and
# commands shadow one by one, not as a directory. Fails if DIR is a personal
# item that is not a directory.
harness_link_each() {
  local u=$1 group=$2 replace=$3 src=$4 dir=$5 child
  if [ "$(link_of "$dir")" = "$src" ]; then rm "$dir"; fi
  [ -e "$dir" ] || install -d -o "$u" -g "$group" -m 0700 "$dir"
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  for child in "$src"/*; do
    [ -e "$child" ] || continue
    harness_link_item "$u" "$group" "$replace" "$child" "$dir/${child##*/}"
  done
}

# harness_unlink_removed DIR SRC: remove only the broken links into SRC, for
# example of a named item that the shared stack removed.
harness_unlink_removed() {
  local link
  while IFS= read -r -d '' link; do
    if [[ $(link_of "$link") == "$2/"* ]] && [ ! -e "$link" ]; then rm -f "$link"; fi
  done < <(find "$1" -type l -print0)
}
