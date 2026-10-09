# shellcheck shell=bash disable=SC2154 # colours come from ui.sh
# Wizard screens: section headers, a checklist, a single choice, a prefilled
# input and a result box. On a terminal that can redraw lines they use the
# arrow keys; otherwise (TERM=dumb, or ONBEHALF_PLAIN=1) numbered prompts.
# Prompts read from /dev/tty and draw on stdout.

MENU_WIDTH=60

menu_fancy() { [ -z "${ONBEHALF_PLAIN:-}" ] && [ "${TERM:-dumb}" != dumb ] && [ -t 1 ]; }

menu_rule() { printf '%s%s%s\n' "$_d" "$(printf '─%.0s' $(seq "$MENU_WIDTH"))" "$_0"; }

# section TITLE [NOTE]: "◆ TITLE  ·  NOTE" with a rule under it.
section() {
  printf '\n%s%s◆ %s%s%s\n' "$_c" "$_b" "$1" "${2:+$_0$_d  ·  $2}" "$_0"
  menu_rule
}

# say TEXT: a plain line of text in a section. note TEXT: the same, dimmed.
say() { printf '  %s\n' "$*"; }
note() { printf '  %s%s%s\n' "$_d" "$*" "$_0"; }

# menu_box COLOUR TITLE: a box around one line.
menu_box() {
  local line pad
  line=$(printf '─%.0s' $(seq $((MENU_WIDTH - 2))))
  pad=$(printf '%*s' $((MENU_WIDTH - 4 - ${#2})) '')
  printf '\n%s┌%s┐\n│  %s%s│\n└%s┘%s\n' "$1" "$line" "$2" "$pad" "$line" "$_0"
}

# menu_key: read one key into KEY: up, down, space, enter, esc or other.
menu_key() {
  local k='' r=''
  IFS= read -rsn1 k </dev/tty || {
    KEY=esc
    return 0
  }
  case $k in
    $'\e')
      IFS= read -rsn2 -t 0.05 r </dev/tty || r=''
      case $r in
        '[A' | OA) KEY=up ;;
        '[B' | OB) KEY=down ;;
        '') KEY=esc ;;
        *) KEY=other ;;
      esac
      ;;
    '') KEY=enter ;;
    ' ') KEY=space ;;
    k) KEY=up ;;
    j) KEY=down ;;
    *) KEY=other ;;
  esac
}

# menu_checklist: choose any of the items in MENU_LABEL, with MENU_STATE
# beside each and MENU_HELP under the list. MENU_ON (1/0) is the selection,
# changed in place; an item with MENU_OFF=1 cannot be selected. MENU_HEAD,
# optional, is a group heading to show before an item. Returns 0 to
# continue, 1 to skip all.
menu_checklist() {
  if menu_fancy; then menu_checklist_keys; else menu_checklist_plain; fi
}

menu_checklist_keys() {
  local n=${#MENU_LABEL[@]} cur=0 i rows drawn=no ptr box name rc=0 extra=0
  rows=$((n + 2))
  # Each heading takes a line, with an empty line before all but the first,
  # and one more empty line before Continue.
  for ((i = 0; i < n; i++)); do
    [ -z "${MENU_HEAD[i]:-}" ] || extra=$((extra + (i > 0 ? 2 : 1)))
  done
  [ "$extra" = 0 ] || extra=$((extra + 1))
  while [ "$cur" -lt "$n" ] && [ "${MENU_OFF[cur]}" = 1 ]; do cur=$((cur + 1)); done
  printf '\e[?25l'
  while :; do
    [ "$drawn" = no ] || printf '\e[%dA' $((rows + extra + 4))
    drawn=yes
    printf '\e[2K  %s↑↓ move   space select   enter confirm   esc skip%s\n\e[2K\n' "$_d" "$_0"
    for ((i = 0; i < rows; i++)); do
      menu_heading "$i" "$n" "$extra" $'\e[2K' '    '
      ptr=' '
      [ "$i" != "$cur" ] || ptr="$_c❯$_0"
      if [ "$i" -ge "$n" ]; then
        [ "$i" = "$n" ] && name="Continue →" || name="Skip for now"
        [ "$i" != "$cur" ] || name="$_b$name$_0"
        printf '\e[2K  %s    %s\n' "$ptr" "$name"
      elif [ "${MENU_OFF[i]}" = 1 ]; then
        printf '\e[2K  %s %s–  %-16s %s%s\n' "$ptr" "$_d" "${MENU_LABEL[i]}" "${MENU_STATE[i]}" "$_0"
      else
        [ "${MENU_ON[i]}" = 1 ] && box="$_g◉$_0" || box='○'
        name=$(printf '%-16s' "${MENU_LABEL[i]}")
        [ "$i" != "$cur" ] || name="$_b$name$_0"
        printf '\e[2K  %s %s  %s %s\n' "$ptr" "$box" "$name" "${MENU_STATE[i]}"
      fi
    done
    printf '\e[2K\n\e[2K  %s' "$_d"
    if [ "$cur" -lt "$n" ]; then
      printf '%s' "${MENU_HELP[cur]}"
    elif [ "$cur" = "$n" ]; then
      printf 'Set up the selected tools now.'
    else
      printf 'Change nothing now.'
    fi
    printf '%s\n' "$_0"
    menu_key
    case $KEY in
      up | down)
        while :; do
          [ "$KEY" = up ] && cur=$(((cur - 1 + rows) % rows)) || cur=$(((cur + 1) % rows))
          [ "$cur" -ge "$n" ] || [ "${MENU_OFF[cur]}" != 1 ] && break
        done
        ;;
      space | enter)
        if [ "$cur" -lt "$n" ]; then
          MENU_ON[cur]=$((1 - MENU_ON[cur]))
        elif [ "$KEY" = enter ]; then
          [ "$cur" = "$n" ] || rc=1
          break
        fi
        ;;
      esc)
        rc=1
        break
        ;;
    esac
  done
  printf '\e[?25h'
  return "$rc"
}

# menu_heading I N EXTRA CLEAR INDENT: the lines before row I of a checklist
# of N items: its heading, or the empty line before Continue if EXTRA is not
# 0. CLEAR starts each line (the code that clears it, or nothing).
menu_heading() {
  if [ "$1" -lt "$2" ] && [ -n "${MENU_HEAD[$1]:-}" ]; then
    [ "$1" = 0 ] || printf '%s\n' "$4"
    printf '%s%s%s%s%s\n' "$4" "$5" "$_d" "${MENU_HEAD[$1]}" "$_0"
  elif [ "$1" = "$2" ] && [ "$3" != 0 ]; then
    printf '%s\n' "$4"
  fi
}

menu_checklist_plain() {
  local n=${#MENU_LABEL[@]} i def='' answer mark
  for ((i = 0; i < n; i++)); do
    menu_heading "$i" "$n" 0 '' '  '
    if [ "${MENU_OFF[i]}" = 1 ]; then
      mark='-  '
    elif [ "${MENU_ON[i]}" = 1 ]; then
      mark='[x]'
      def="$def $((i + 1))"
    else
      mark='[ ]'
    fi
    printf '  %d) %s %-16s %s\n' $((i + 1)) "$mark" "${MENU_LABEL[i]}" "${MENU_STATE[i]}"
  done
  while :; do
    def=${def# }
    read -r -p "  Numbers to set up, 0 for none [${def:-0}]: " answer </dev/tty || answer=0
    [ -n "$answer" ] || answer=${def:-0}
    [ "$answer" != 0 ] || return 1
    answer=${answer//,/ }
    for i in $answer; do
      [[ $i =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "$n" ] && [ "${MENU_OFF[i - 1]}" != 1 ] || {
        printf '  %s!%s select from the numbers above\n' "$_y" "$_0"
        continue 2
      }
    done
    for ((i = 0; i < n; i++)); do MENU_ON[i]=0; done
    for i in $answer; do MENU_ON[i - 1]=1; done
    return 0
  done
}

# menu_choice VAR OPTION...: choose one option; VAR gets its index (0 = first,
# the default).
menu_choice() {
  local -n _choice=$1
  shift
  local opts=("$@") n=$# cur=0 i drawn=no answer
  if ! menu_fancy; then
    for ((i = 0; i < n; i++)); do printf '  %d) %s\n' $((i + 1)) "${opts[i]}"; done
    while :; do
      read -r -p "  Choice [1]: " answer </dev/tty || answer=1
      answer=${answer:-1}
      if [[ $answer =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le "$n" ]; then
        _choice=$((answer - 1))
        return 0
      fi
    done
  fi
  printf '\e[?25l'
  while :; do
    [ "$drawn" = no ] || printf '\e[%dA' "$n"
    drawn=yes
    for ((i = 0; i < n; i++)); do
      if [ "$i" = "$cur" ]; then
        printf '\e[2K  %s❯%s %s●%s %s%s%s\n' "$_c" "$_0" "$_g" "$_0" "$_b" "${opts[i]}" "$_0"
      else
        printf '\e[2K    ○ %s\n' "${opts[i]}"
      fi
    done
    menu_key
    case $KEY in
      up) cur=$(((cur - 1 + n) % n)) ;;
      down) cur=$(((cur + 1) % n)) ;;
      enter) break ;;
    esac
  done
  printf '\e[?25h'
  _choice=$cur
}

# menu_input VAR LABEL [VALUE]: one line of text, prefilled with VALUE that
# can be edited (on a terminal that can redraw lines).
menu_input() {
  if menu_fancy; then
    read -e -r -i "${3:-}" -p $'  \001'"$_y"$'\002'"$2"$': \001'"$_0"$'\002' "$1" </dev/tty || printf -v "$1" ''
  else
    ask "$1" "$2" "${3:-}"
  fi
}
