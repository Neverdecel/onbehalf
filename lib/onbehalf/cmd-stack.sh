# shellcheck shell=bash
# onbehalf stack install: copy a stack directory into an immutable release
# and make it current with an atomic symlink switch.

cmd_stack_install() {
  need_root
  load_conf
  local src="" restart=yes
  while [ $# -gt 0 ]; do
    case $1 in
      --no-restart)
        restart=no
        shift
        ;;
      -*) die "unknown option: $1" ;;
      *)
        src=$1
        shift
        ;;
    esac
  done
  [ -d "$src" ] || die "usage: onbehalf stack install [--no-restart] DIR"
  stack_validate "$src"
  local available models
  models=$(stack_models "$src")
  available=$(gateway_admin GET /v1/models | jq -ce '[.data[].id]') || die "could not read the models of the gateway. The shared stack did not change"
  jq -en --argjson models "$models" --argjson available "$available" '$models - $available | length == 0' >/dev/null \
    || die "the model catalog has models that the gateway does not serve. The shared stack did not change"

  # The release id is a hash of the content, so the same stack gives the same id.
  local id rel tmp
  id=$(cd "$src" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)
  rel="$ONBEHALF_STACK/releases/$id"

  if [ ! -d "$rel" ]; then
    install -d -m 0755 "$ONBEHALF_STACK" "$ONBEHALF_STACK/releases"
    tmp=$(mktemp -d "$ONBEHALF_STACK/releases/.new.XXXXXX")
    cp -R "$src"/. "$tmp"/
    # Fill in host settings; the stack in Git stays host-independent.
    # A stack source with models.json can have no placeholder: grep then finds nothing.
    { grep -rlZ '@GATEWAY_URL@' "$tmp" || true; } | xargs -0 -r sed -i "s#@GATEWAY_URL@#$ONBEHALF_GATEWAY_URL#g"
    harness_build "$tmp"
    chown -R root:root "$tmp"
    chmod -R u=rwX,go=rX "$tmp"
    mv "$tmp" "$rel"
  fi

  # Restrict existing keys before activating the catalog. If the gateway fails,
  # leave the current release unchanged. A retry repairs partially updated keys.
  local u home
  for u in $(people); do gateway_models_update "$u" "$models"; done

  ln -sfn "releases/$id" "$ONBEHALF_STACK/current.new"
  mv -T "$ONBEHALF_STACK/current.new" "$ONBEHALF_STACK/current"
  ok "shared stack $id is current"

  # Every user gets the change now: new links, and running services restart.
  # --no-restart leaves running services on the old config until they restart.
  for u in $(people); do
    home=$(getent passwd "$u" | cut -d: -f6)
    harness stack_changed "$u" "$home" "$(id -gn "$u")" "$restart"
  done
}
