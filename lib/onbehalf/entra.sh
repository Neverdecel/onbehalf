# Entra ID: the users on this host follow the members of one Entra group.
#
# onbehalf stores no Entra credential. `user sync` reads the group with the
# Azure CLI login of the operator who runs sudo, or from a file (--from).
# The link between a Linux account and an Entra account is the Entra object
# id, not the UPN: a renamed user keeps their account.

ENTRA_MAP=${ENTRA_MAP:-$ONBEHALF_ETC/entra.map} # lines: NAME OBJECT-ID UPN
ENTRA_CONF=${ENTRA_CONF:-$ONBEHALF_ETC/entra.conf}
GRAPH_URL=https://graph.microsoft.com/v1.0

# The Entra group that sync follows, if one is set.
entra_group() {
  [ -r "$ENTRA_CONF" ] || return 0
  # shellcheck source=/dev/null
  (. "$ENTRA_CONF" && echo "${ONBEHALF_ENTRA_GROUP:-}")
}

entra_valid_id() {
  local LC_ALL=C
  [[ $1 =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

# Lookups in the map. Each prints nothing if there is no link.
entra_id_of() { [ -r "$ENTRA_MAP" ] && awk -v n="$1" '$1 == n { print $2 }' "$ENTRA_MAP" || true; }
entra_upn_of() { [ -r "$ENTRA_MAP" ] && awk -v n="$1" '$1 == n && $3 != "-" { print $3 }' "$ENTRA_MAP" || true; }
entra_name_of() { [ -r "$ENTRA_MAP" ] && awk -v i="$1" '$2 == i { print $1 }' "$ENTRA_MAP" || true; }

# entra_link NAME ID [UPN]: add or replace the link of NAME and of ID.
entra_link() {
  local tmp
  tmp=$(mktemp "$ENTRA_MAP.XXXXXX")
  {
    [ -r "$ENTRA_MAP" ] && awk -v n="$1" -v i="$2" '$1 != n && $2 != i' "$ENTRA_MAP"
    printf '%s %s %s\n' "$1" "$2" "${3:--}"
  } | sort >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$ENTRA_MAP"
}

entra_unlink() {
  [ -n "$(entra_id_of "$1")" ] || return 0
  local tmp
  tmp=$(mktemp "$ENTRA_MAP.XXXXXX")
  awk -v n="$1" '$1 != n' "$ENTRA_MAP" >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$ENTRA_MAP"
}

# Account name from a UPN: alice.smith@corp.com becomes alice-smith.
# Prints nothing if the result is no valid account name (for example a guest).
entra_derive_name() {
  local LC_ALL=C n=${1%@*}
  n=${n,,}
  [[ $n != *'#ext#'* ]] || return 0
  n=${n//./-}
  account_name_valid "$n" && echo "$n" || true
}

# Members of GROUP as lines "ID UPN ENABLED" (ENABLED: true, false or unknown).
# Users only; nested groups count. Fails if Entra cannot be read.
entra_members() {
  local group=$1 from=$2 json list
  if [ -n "$from" ]; then
    json=$(cat -- "$from") || die "could not read $from"
  else
    json=$(entra_graph_members "$group") || exit 1
  fi
  # Accepts the output of `az ad group member list` and of Graph ({value:[...]}).
  list=$(jq -ec 'if type == "object" then .value else . end | arrays' <<<"$json" 2>/dev/null) \
    || die "the member list is not a JSON list of Entra users"
  jq -r '.[] | select((."@odata.type" // "#microsoft.graph.user") == "#microsoft.graph.user")
      | "\(.id | ascii_downcase) \(.userPrincipalName) \(if .accountEnabled == null then "unknown" else .accountEnabled end)"' \
    <<<"$list"
}

# All user members of GROUP from Microsoft Graph, through the Azure CLI login
# of the operator. Pages are joined into one JSON array.
entra_graph_members() {
  local group=$1 op=${SUDO_USER:-} gid url page all='[]'
  if [ -z "$op" ] || [ "$op" = root ]; then
    die "run this with sudo from your own account. onbehalf uses your Azure CLI login to read Entra.
          Or give the member list: az ad group member list --group GROUP -o json | sudo onbehalf user sync --from -"
  fi
  as_user "$op" "command -v az" >/dev/null || die "the Azure CLI (az) is not installed for $op"

  if entra_valid_id "${group,,}"; then
    gid=${group,,}
  else
    gid=$(entra_az "$op" "az ad group show --group $(printf %q "$group") --query id -o tsv") || exit 1
  fi

  url="$GRAPH_URL/groups/$gid/transitiveMembers/microsoft.graph.user?\$select=id,userPrincipalName,accountEnabled&\$top=999"
  while [ -n "$url" ]; do
    page=$(entra_az "$op" "az rest --method get --url $(printf %q "$url")") || exit 1
    all=$(jq -c --argjson all "$all" '$all + .value' <<<"$page") || die "Entra returned no member list"
    url=$(jq -r '."@odata.nextLink" // empty' <<<"$page")
  done
  echo "$all"
}

# entra_az OP COMMAND: run an Azure CLI command as OP and print its output.
# Warnings on stderr stay out of the output; on failure they are the message.
entra_az() {
  local out errs
  errs=$(mktemp)
  if out=$(as_user "$1" "$2" 2>"$errs"); then
    rm -f "$errs"
    echo "$out"
    return
  fi
  out=$(<"$errs")
  rm -f "$errs"
  die "the Azure CLI failed as $1: ${out:-no message}
          fix: log in as $1 with: az login; check the group name"
}

# onbehalf user sync: make the users on this host follow an Entra group.
cmd_user_sync() {
  need_root
  load_conf
  local group='' from='' remove=no dry=no
  while [ $# -gt 0 ]; do
    case $1 in
      --group)
        group=${2:-}
        shift 2
        ;;
      --from)
        from=${2:-}
        shift 2
        ;;
      --remove)
        remove=yes
        shift
        ;;
      --dry-run)
        dry=yes
        shift
        ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$group" ] || group=$(entra_group)
  [ -n "$group" ] || die "usage: onbehalf user sync --group GROUP [--from FILE] [--remove] [--dry-run]"
  [ -e "$ONBEHALF_STACK/current" ] || die "no shared stack yet. Run: sudo onbehalf stack install DIR"
  [ "$from" != - ] || from=/dev/stdin
  [ -z "$from" ] || [ -r "$from" ] || die "cannot read $from"

  heading "Entra group $group"
  local members
  members=$(entra_members "$group" "$from") || exit 1
  # An empty group is far more likely a wrong group or a failed read than a
  # team without people. Never offboard everyone on that signal.
  [ -n "$members" ] || die "the group '$group' has no user members in Entra. Nothing changed"
  ok "$(wc -l <<<"$members") member(s), read $([ -n "$from" ] && echo "from $from" || echo "as $SUDO_USER")"
  if [ "$dry" = no ]; then
    printf 'ONBEHALF_ENTRA_GROUP=%q\n' "$group" >"$ENTRA_CONF"
    chmod 0644 "$ENTRA_CONF"
  fi

  heading "Members"
  local id upn enabled name linked new=() planned=" " active=" "
  while read -r id upn enabled; do
    if [ "$enabled" = false ]; then
      info "$upn is disabled in Entra"
      continue
    fi
    active="$active$id "
    name=$(entra_name_of "$id")
    if [ -n "$name" ] && id "$name" >/dev/null 2>&1; then
      # Keep the UPN current: a user can be renamed in Entra.
      [ "$(entra_upn_of "$name")" = "$upn" ] || [ "$dry" = yes ] || entra_link "$name" "$id" "$upn"
      ok "$name is $upn"
      continue
    fi
    if [ -z "$name" ]; then
      name=$(entra_derive_name "$upn")
      if [ -z "$name" ]; then
        err "$upn: no valid account name. onbehalf cannot make one from this UPN"
        fix "sudo onbehalf user add --entra-id $id <name>"
        continue
      fi
      linked=$(entra_id_of "$name")
      if [ -n "$linked" ]; then
        err "$upn: the account $name belongs to a different Entra account ($linked)"
        fix "sudo onbehalf user add --entra-id $id <other name>"
        continue
      fi
      # An existing account with the same name may be a different user.
      # Link it only on the explicit word of the operator.
      if id "$name" >/dev/null 2>&1; then
        err "$upn: the account $name exists, but is not linked to Entra"
        fix "if $name is $upn: sudo onbehalf user add --entra-id $id $name"
        continue
      fi
      case $planned in *" $name "*)
        err "$upn: another new member also gets the account name $name"
        fix "sudo onbehalf user add --entra-id $id <other name>"
        continue
        ;;
      esac
    fi
    planned="$planned$name "
    info "$([ "$dry" = yes ] && echo "would add" || echo "new:") $name for $upn"
    new+=("$name $id $upn")
  done <<<"$members"

  if [ "$dry" = no ]; then
    for name in "${new[@]}"; do
      read -r name id upn <<<"$name"
      user_add_one "$name" no "$id" "$upn"
    done
  fi

  heading "Users who are not active members now"
  local n=0 removed=no
  while read -r name id upn; do
    [ -n "$name" ] || continue
    case $active in *" $id "*) continue ;; esac
    n=$((n + 1))
    [ "$upn" != - ] || upn=$id
    if [ "$remove" = no ]; then
      warn "$name ($upn) is not an active member of the group"
      fix "sudo onbehalf user sync --remove"
    elif [ "$dry" = yes ]; then
      info "would remove $name ($upn)"
    else
      user_remove_one "$name"
      removed=yes
    fi
  done < <(cat "$ENTRA_MAP" 2>/dev/null || true)
  [ "$n" -gt 0 ] || ok "none"

  local u others=
  for u in $(people); do [ -n "$(entra_id_of "$u")" ] || others="$others $u"; done
  [ -z "$others" ] || info "not linked to Entra, sync does not change them:$others"

  [ ${#new[@]} -eq 0 ] || [ "$dry" = yes ] || onboarding_steps
  if [ "$removed" = yes ]; then
    heading "Also revoke removed users outside this host"
    echo "  The GitHub organization and other accounts that Entra does not control."
  fi
  [ "$UI_ERRORS" = 0 ] || exit 1
}
