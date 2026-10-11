# shellcheck shell=bash
# The AI harness of the host. The operator selects one AI harness for each
# host. Each adapter, harness-NAME.sh, gives the functions harness_NAME_OP.

# The AI harnesses that onbehalf supports, in the order of their directories.
HARNESSES=(opencode claude)

# The AI harness of the host. A host without the setting uses OpenCode.
harness_id() { echo "${ONBEHALF_HARNESS:-opencode}"; }

# True if NAME is an AI harness that onbehalf supports.
harness_known() {
  local h
  for h in "${HARNESSES[@]}"; do [ "$h" != "$1" ] || return 0; done
  return 1
}

# harness OP [ARGS]: call OP of the adapter of the AI harness of the host.
harness() {
  local op=$1 h
  shift
  h=$(harness_id)
  harness_known "$h" || die "the AI harness '$h' in $ONBEHALF_ETC/onbehalf.conf is not one of: ${HARNESSES[*]}"
  "harness_${h}_$op" "$@"
}

# Check the harness directories of a stack source. The adapter of the host
# always checks, because a stack source with only models.json, AGENTS.md
# and skills/ serves each AI harness.
harness_validate() {
  local h
  for h in "${HARNESSES[@]}"; do
    if [ -d "$1/$h" ] || [ "$h" = "$(harness_id)" ]; then "harness_${h}_validate" "$1"; fi
  done
}

# Build a new release directory: give the harness instructions and the
# skills at the root to each AI harness. With models.json, each adapter
# writes the model catalog into the configuration of its AI harness.
harness_build() {
  local rel=$1 h
  for h in "${HARNESSES[@]}"; do
    [ -d "$rel/$h" ] || [ -e "$rel/models.json" ] || continue
    install -d "$rel/$h"
    [ ! -e "$rel/AGENTS.md" ] || cp "$rel/AGENTS.md" "$rel/$h/AGENTS.md"
    if [ -d "$rel/skills" ]; then
      install -d "$rel/$h/skills"
      cp -R "$rel/skills/." "$rel/$h/skills/"
    fi
    [ ! -e "$rel/models.json" ] || "harness_${h}_build" "$rel"
  done
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
