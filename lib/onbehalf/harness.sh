# shellcheck shell=bash
# The AI harness of the host. The operator selects one AI harness for each
# host. Each adapter, harness-NAME.sh, gives the functions harness_NAME_OP.

# The AI harnesses that onbehalf supports, in the order of their directories.
HARNESSES=(opencode)

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
