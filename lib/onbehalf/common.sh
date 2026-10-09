# shellcheck shell=bash
# Shared helpers for onbehalf commands.

ONBEHALF_ETC=${ONBEHALF_ETC:-/etc/onbehalf}
# Docs and examples: installed in PREFIX/share/onbehalf, or the checkout itself.
if [ -z "${ONBEHALF_SHARE:-}" ]; then
  if [ -d "$ONBEHALF_LIB/../../share/onbehalf" ]; then
    ONBEHALF_SHARE=$(readlink -f "$ONBEHALF_LIB/../../share/onbehalf")
  else
    ONBEHALF_SHARE=$(readlink -f "$ONBEHALF_LIB/../..")
  fi
fi

die() {
  echo "onbehalf: $*" >&2
  exit 1
}
need_root() { [ "$(id -u)" = 0 ] || die "run this command as root: sudo onbehalf ${ONBEHALF_CMD:-}"; }

load_conf() {
  [ -r "$ONBEHALF_ETC/onbehalf.conf" ] || die "this host is not set up yet. Run: sudo onbehalf init"
  . "$ONBEHALF_ETC/onbehalf.conf"
}

# Users who joined at their first login, one file each. The modification
# time of a file is the last login of that user.
ENROLL_STATE=${ENROLL_STATE:-/var/lib/onbehalf/enrolled}

# Users on this host: accounts that have an onbehalf gateway key. Directory
# accounts (Entra login) may not be listed by getent; enrolled ones still count.
people() {
  local name uid home
  while IFS=: read -r name _ uid _ _ home _; do
    if [ "$uid" -ge 1000 ] && [ -e "$home/.config/onbehalf/gateway.key" ]; then
      echo "$name"
    fi
  done < <(
    {
      getent passwd
      enrolled_names | xargs -r getent passwd
    } | awk -F: '!seen[$1]++'
  )
}

enrolled_names() { [ -d "$ENROLL_STATE" ] && ls -A "$ENROLL_STATE" || true; }

# Past users, one file each: onbehalf revoked their access. The
# modification time of a file is the time of the revocation. The report shows
# their model use as the use of past users. Root only.
REMOVED_STATE=${REMOVED_STATE:-/var/lib/onbehalf/removed}
removed_mark() {
  install -d -m 0700 "$REMOVED_STATE"
  touch "$REMOVED_STATE/$1"
}
removed_clear() { rm -f "$REMOVED_STATE/$1"; }

# Name rules use LC_ALL=C. In other locales, [a-z] can match letters that are
# not ASCII (for example å), and ${n,,} can change İ to i.

# Account names onbehalf accepts. Wider than useradd: the Entra login of Azure
# VMs makes accounts named by UPN, for example alice.smith@corp.com.
user_name_valid() {
  local LC_ALL=C
  [[ $1 =~ ^[a-z0-9_][a-z0-9._@-]{0,63}$ ]]
}

# Names for new local accounts: portable for useradd.
account_name_valid() {
  local LC_ALL=C
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

# Accounts that only a directory service knows (not in /etc/passwd) cannot be
# locked or deleted with usermod and userdel.
local_account() { awk -F: -v n="$1" '$1 == n { f = 1 } END { exit !f }' /etc/passwd; }

home_of() { getent passwd "$1" | cut -d: -f6; }

# Target of a symlink, or nothing if PATH is no symlink.
link_of() { readlink "$1" 2>/dev/null || true; }

# Run a command as a user, in a clean login shell (no root environment).
as_user() { runuser -l "$1" -c "$2" </dev/null; }

# Call the gateway with a key from a file: gateway_call KEYFILE METHOD PATH [JSON].
# The key goes in through a file descriptor, never on a command line, because
# every user can read the command lines of all processes in /proc.
gateway_call() {
  curl -fsS --max-time 10 -X "$2" "$ONBEHALF_GATEWAY_URL$3" \
    -H @<(printf 'Authorization: Bearer %s\n' "$(<"$1")") \
    -H 'Content-Type: application/json' ${4:+--data "$4"}
}

gateway_admin() { gateway_call "$ONBEHALF_ETC/gateway-admin.key" "$@"; }

# Personal keys permit inference and reading the user's own model use only,
# even if the owner has a gateway admin role. The gateway answers
# /user/daily/activity for a personal key with that key's own use only.
GATEWAY_USER_ROUTES='["/models","/v1/models","/chat/completions","/v1/chat/completions","/responses","/v1/responses","/messages","/v1/messages","/user/daily/activity"]'

# A model ID must be the model_name of a gateway model. Never send an empty
# list: LiteLLM treats it as unrestricted.
STACK_MODEL_IDS_OK='unique | select(length > 0 and all(.[]; type == "string" and
  test("^[a-zA-Z0-9][a-zA-Z0-9._/-]*$") and
  . != "all-proxy-models" and . != "all-team-models"))'

# The model catalog of a stack directory (a stack source or a release).
# models.json is the catalog for each AI harness. A stack without it keeps
# the catalog in the providers of opencode/opencode.json, as onbehalf 0.1.0.
stack_models() {
  if [ -e "$1/models.json" ]; then
    jq -ce "[.models // {} | keys_unsorted[]] | $STACK_MODEL_IDS_OK" "$1/models.json"
  else
    harness_opencode_models "$1/opencode/opencode.json"
  fi
}

# The model a check uses: the stack default, else the first model of the catalog.
stack_default_model() {
  if [ -e "$1/models.json" ]; then
    jq -er '.model // (.models | keys_unsorted[0])' "$1/models.json"
  else
    harness_opencode_default_model "$1/opencode/opencode.json"
  fi
}

# models.json: {"model": ID, "models": {ID: {"api": "openai" | "anthropic"}}}.
# "model" (the default) and "api" (default "openai") are optional.
stack_catalog_valid() {
  jq -e "
    type == \"object\" and (keys - [\"model\", \"models\"] | length == 0) and
    (.models | type == \"object\") and
    ([.models | keys_unsorted[]] | $STACK_MODEL_IDS_OK | length > 0) and
    all(.models[]; type == \"object\" and (keys - [\"api\"] | length == 0) and
      ((has(\"api\") | not) or .api == \"openai\" or .api == \"anthropic\")) and
    ((has(\"model\") | not) or (.model as \$m | .models | has(\$m)))
  " "$1" >/dev/null 2>&1
}

# The harness instructions and the skills at the root are for each AI
# harness. A harness directory must not have an item with the same name.
stack_shared_valid() {
  local h skill
  if [ -d "$1/skills" ]; then
    for skill in "$1"/skills/*; do
      [ -e "$skill" ] || continue
      [ -f "$skill/SKILL.md" ] || die "skills/${skill##*/}: each skill must be a directory with a SKILL.md"
    done
  fi
  for h in "${HARNESSES[@]}"; do
    if [ -e "$1/AGENTS.md" ] && [ -e "$1/$h/AGENTS.md" ]; then
      die "AGENTS.md is at the root and in $h/. Keep one of them"
    fi
    for skill in "$1"/skills/*; do
      [ -e "$skill" ] || continue
      [ ! -e "$1/$h/skills/${skill##*/}" ] || die "the skill ${skill##*/} is in skills/ and in $h/skills/. Keep one of them"
    done
  done
}

stack_validate() {
  if [ -e "$1/models.json" ]; then
    stack_catalog_valid "$1/models.json" \
      || die "models.json must have one or more models, with an optional \"api\" of openai or anthropic. The default \"model\" must be one of them"
  fi
  stack_shared_valid "$1"
  harness_validate "$1"
  local f id
  for f in "$1"/tools/*.json; do
    [ -e "$f" ] || continue
    id=${f##*/} id=${id%.json}
    stack_tool_id_ok "$id" || die "tools/${f##*/}: the name must be lowercase letters, digits and -, and must not be a built-in work tool (${TOOL_BUILTIN[*]})"
    stack_tool_valid "$f" || die "tools/${f##*/}: label, help and command must be one line of text. check and login must be lists of one or more arguments. whoami is optional. No other keys"
  done
}

# A work tool of the shared stack, tools/ID.json: a new ID, never a built-in.
stack_tool_id_ok() {
  [[ $1 =~ ^[a-z][a-z0-9-]*$ ]] || return 1
  local b
  for b in "${TOOL_BUILTIN[@]}"; do [ "$1" != "$b" ] || return 1; done
}

# stack_tool_valid FILE: the file has the fields of a work tool and no others.
# Commands are lists of arguments: the stack never gives shell code.
stack_tool_valid() {
  jq -e '
    def line: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
    def args: type == "array" and length > 0 and all(.[]; line);
    type == "object" and
    (keys - ["label", "help", "command", "check", "login", "whoami"] | length == 0) and
    (.label | line) and (.help | line) and (.command | line) and
    (.check | args) and (.login | args) and ((has("whoami") | not) or (.whoami | args))
  ' "$1" >/dev/null 2>&1
}

gateway_models_update() {
  local u=$1 models=$2 token body
  token=$(sha256sum "$(home_of "$u")/.config/onbehalf/gateway.key" | cut -d' ' -f1)
  body=$(jq -nc --arg key "$token" --argjson models "$models" --argjson routes "$GATEWAY_USER_ROUTES" \
    '{key: $key, models: $models, allowed_routes: $routes}')
  gateway_admin POST /key/update "$body" >/dev/null || die "could not update the model access of $u. Install the shared stack again"
  gateway_models_match "$u" "$models" || die "the model access of $u on the gateway is not the same as the model catalog. Install the shared stack again"
}

# gateway_key_policy NAME MODELS: ok, models (the key permits other models),
# or routes (only the routes are of an older onbehalf).
gateway_key_policy() {
  local token
  token=$(sha256sum "$(home_of "$1")/.config/onbehalf/gateway.key" | cut -d' ' -f1)
  gateway_admin GET "/key/info?key=$token" 2>/dev/null | jq -r --argjson models "$2" --argjson routes "$GATEWAY_USER_ROUTES" '
    if (.info.models | sort) != $models then "models"
    elif .info.allowed_routes != $routes then "routes" else "ok" end' 2>/dev/null || echo models
}

gateway_models_match() {
  local token
  token=$(sha256sum "$(home_of "$1")/.config/onbehalf/gateway.key" | cut -d' ' -f1)
  gateway_admin GET "/key/info?key=$token" | jq -e --argjson models "$2" --argjson routes "$GATEWAY_USER_ROUTES" \
    '(.info.models | sort) == $models and .info.allowed_routes == $routes' >/dev/null \
    2>/dev/null
}

# model_access_check KEYFILE MODEL WHO: send one short chat request through the
# gateway and say who refused it, if it fails. A gateway that answers and
# accepts keys can still have a provider that refuses every request.
model_access_check() {
  local keyfile=$1 model=$2 who=$3 out code msg
  info "one request to $model as $who, with a maximum of 16 output tokens. It is model use of $who"
  out=$(curl -sS --max-time 60 -w '\n%{http_code}' -X POST "$ONBEHALF_GATEWAY_URL/v1/chat/completions" \
    -H @<(printf 'Authorization: Bearer %s\n' "$(<"$keyfile")") -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg m "$model" '{model: $m, max_tokens: 16,
      messages: [{role: "user", content: "Reply with the word ok."}]}')" 2>/dev/null) || true
  code=${out##*$'\n'}
  msg=$(jq -r '.error.message // .detail // empty | tostring' <<<"${out%$'\n'*}" 2>/dev/null) || msg=
  # LiteLLM prefixes errors from the provider with "litellm.<Error>: ... Exception - ".
  local upstream=no
  if [[ $msg == litellm.* ]]; then
    upstream=yes
    msg=${msg%%$'\n'*}
    [[ $msg != *"Exception - "* ]] || msg=${msg#*Exception - }
  fi
  msg=${msg//$'\n'/ }
  msg=${msg:0:300}

  case $code:$upstream in
    200:*)
      ok "$model answered: the model provider accepts requests from the gateway"
      return 0
      ;;
    000:*)
      err "no answer from the gateway within 60 seconds"
      fix "make sure that the gateway can connect to the provider. See the operator guide, section 'Model access fails'"
      ;;
    401:no | 403:no)
      err "the gateway refused the request (HTTP $code): $msg"
      fix "the model must be in the shared stack and on the gateway. Check with: sudo onbehalf doctor"
      ;;
    401:yes | 403:yes)
      err "the model provider refused the request (HTTP $code): $msg"
      fix "check the network rules and the key of the provider. See the operator guide, section 'Model access fails'"
      ;;
    404:*)
      err "the model provider does not know this model (HTTP 404): $msg"
      fix "check the deployment name, api_base and api_version of $model in the gateway configuration"
      ;;
    429:*)
      err "the model provider limits requests (HTTP 429): $msg"
      fix "check the quota of the deployment, then try again"
      ;;
    *)
      err "the model request failed (HTTP $code): ${msg:-no error message}"
      fix "check the logs of the gateway. See the operator guide, section 'Model access fails'"
      ;;
  esac
  return 1
}
