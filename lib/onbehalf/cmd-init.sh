# shellcheck shell=bash
# onbehalf init: connect this host to a model gateway, for one AI harness.
# Asks on a terminal; otherwise takes --gateway-url, --harness and the admin
# key on stdin. Nothing is saved until the gateway answers, accepts the key
# and serves the API of the AI harness.

cmd_init() {
  need_root
  local url="" key problem out code msg harness="" missing
  while [ $# -gt 0 ]; do
    case $1 in
      --gateway-url)
        url=${2:-}
        shift 2
        ;;
      --harness)
        harness=${2:-}
        shift 2
        ;;
      *) die "unknown option: $1" ;;
    esac
  done
  # Keep the AI harness of the host when init runs again.
  [ -n "$harness" ] || harness=${ONBEHALF_HARNESS:-}
  if [ -z "$harness" ] && [ -r "$ONBEHALF_ETC/onbehalf.conf" ]; then
    harness=$(sed -n 's/^ONBEHALF_HARNESS=//p' "$ONBEHALF_ETC/onbehalf.conf")
  fi
  if [ -z "$harness" ] && [ -t 0 ] && [ ${#HARNESSES[@]} -gt 1 ]; then
    info "Select the AI harness of this host: ${HARNESSES[*]}. The model gateway must serve its API."
    ask harness "AI harness" opencode
  fi
  harness=${harness:-opencode}
  harness_known "$harness" || die "the AI harness must be one of: ${HARNESSES[*]}"
  ONBEHALF_HARNESS=$harness

  heading "Connect this host to the model gateway"
  if [ -t 0 ]; then
    info "The gateway URL is the address of LiteLLM, for example http://127.0.0.1:4000."
    info "It is not the endpoint of the model provider, such as an Azure AI Foundry URL."
    info "The admin key is the LITELLM_MASTER_KEY of the gateway, not a provider key."
    [ -n "$url" ] || ask url "Gateway URL (LiteLLM)" "${ONBEHALF_GATEWAY_URL:-http://127.0.0.1:4000}"
    while problem=$(gateway_url_problem "$url"); do
      err "$problem"
      ask url "Gateway URL (LiteLLM)" "http://127.0.0.1:4000"
    done
    ask_secret key "Admin key of the gateway (LITELLM_MASTER_KEY)"
  else
    key=$(cat)
  fi
  [ -n "$url" ] || die "give --gateway-url"
  [ -n "$key" ] || die "give the admin key of the gateway (on stdin, or in the terminal)"
  if problem=$(gateway_url_problem "$url"); then
    err "$problem"
    fix "give the LiteLLM address, for example: --gateway-url http://127.0.0.1:4000"
    exit 1
  fi
  url=${url%/}
  url=${url%/v1}

  if curl -fsS --max-time 10 "$url/health/liveliness" >/dev/null 2>&1; then
    ok "gateway $url answers"
  else
    err "gateway $url does not answer"
    fix "start the gateway, or check the URL. onbehalf kept nothing"
    gateway_guide
    heading "Continue when the gateway runs"
    echo "  sudo onbehalf init --gateway-url $url"
    exit 1
  fi

  # Listing keys needs a valid admin key and the gateway database.
  out=$(curl -sS --max-time 10 -w '\n%{http_code}' "$url/key/list?size=1" \
    -H @<(printf 'Authorization: Bearer %s\n' "$key") 2>/dev/null) || true
  code=${out##*$'\n'}
  msg=$(jq -r '.error.message // .detail // empty | tostring' <<<"${out%$'\n'*}" 2>/dev/null) || msg=
  case $code in
    200) ok "the admin key is valid" ;;
    401 | 403)
      err "the gateway does not accept this admin key"
      fix "use the LITELLM_MASTER_KEY of the gateway, not a model provider key"
      exit 1
      ;;
    *)
      err "the gateway cannot manage keys (HTTP $code): ${msg:0:200}"
      fix "onbehalf must have LiteLLM with a PostgreSQL database (DATABASE_URL). See the operator guide, section 'Model gateway'"
      exit 1
      ;;
  esac
  if [ "$(curl -fsS --max-time 10 "$url/v1/models" -H @<(printf 'Authorization: Bearer %s\n' "$key") 2>/dev/null \
    | jq '.data | length' 2>/dev/null || echo 0)" -gt 0 ]; then
    ok "the gateway has models"
  else
    warn "the gateway has no models yet"
    fix "an operator adds each model deployment to the LiteLLM configuration"
  fi
  ONBEHALF_GATEWAY_URL=$url
  missing=$(gateway_api_missing)
  if [ -z "$missing" ]; then
    ok "the gateway serves the API of $(harness label)"
  else
    err "the gateway does not serve the API of $(harness label): ${missing//$'\n'/ }"
    fix "use a LiteLLM version that serves these routes. See the operator guide, section 'Model gateway'. onbehalf kept nothing"
    exit 1
  fi

  install -d -m 0755 "$ONBEHALF_ETC" || die "could not create $ONBEHALF_ETC"
  (
    umask 077
    printf %s "$key" >"$ONBEHALF_ETC/gateway-admin.key"
  ) || die "could not save the admin key"
  cat >"$ONBEHALF_ETC/onbehalf.conf" <<EOF || die "could not save $ONBEHALF_ETC/onbehalf.conf"
# onbehalf host configuration. Readable by all users; contains no secrets.
ONBEHALF_GATEWAY_URL=$url
ONBEHALF_HARNESS=$harness
ONBEHALF_STACK=/opt/onbehalf/stack
ONBEHALF_PORT_BASE=40000
EOF
  chmod 0644 "$ONBEHALF_ETC/onbehalf.conf"
  ok "saved $ONBEHALF_ETC/onbehalf.conf and the admin key (root only)"

  heading "Next"
  echo "  sudo onbehalf stack install <stack source>"
  echo "      example stack: $ONBEHALF_SHARE/examples/stack"
}

# Prints why URL cannot be a gateway URL; fails if it can be one.
gateway_url_problem() {
  local host
  [[ $1 =~ ^https?://([^/:]+) ]] || {
    echo "the gateway URL must start with http:// or https://"
    return 0
  }
  host=${BASH_REMATCH[1],,}
  case $host in
    *.openai.azure.com | *.services.ai.azure.com | *.cognitiveservices.azure.com | *.models.ai.azure.com | *.inference.ai.azure.com)
      echo "$host is an Azure AI Foundry endpoint, not the gateway. Put it in the LiteLLM configuration as api_base"
      ;;
    api.openai.com | api.anthropic.com)
      echo "$host is a model provider endpoint, not the gateway. Put it in the LiteLLM configuration"
      ;;
    *) return 1 ;;
  esac
}

# What the gateway admin does before a host can connect.
gateway_guide() {
  info "The gateway is LiteLLM with a PostgreSQL database. An operator runs it,"
  info "on this host or on another host. onbehalf does not install it."
  info "  1. Start from the example: $ONBEHALF_SHARE/examples/gateway"
  info "  2. Put the model provider keys in the .env file of the gateway (mode 600)."
  info "     Azure AI Foundry: copy the key and endpoint of each deployment from the Foundry portal."
  info "     If the Foundry resource permits only selected networks, permit the outbound address of the gateway."
  info "  3. Add each deployment to litellm.yaml. Its model_name is the name that users see."
  info "  4. Check from this host: curl http://<gateway>:4000/health/liveliness"
  info "Operator guide: $ONBEHALF_SHARE/docs/operator-guide.md, section 'Model gateway'"
}
