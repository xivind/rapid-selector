# Shared helpers for rapidselector.sh and the scripts in scripts/: settings and secrets,
# and calls to the gateway.
# Run:     source it, do not run it (rapidselector.sh and every routine script do).
# Secrets: RAPIDSELECTOR_SECRETS and RAPIDSELECTOR_OPTIONAL_SECRETS below are the only lists of
#          their names; they come from .env (SECRETS_SOURCE=env) or from the secret
#          "rapidselector" in secrets-service.
# Cost:    nothing.
# Exit:    through die: 2 no settings file or a wrong SECRETS_SOURCE, 3 a missing value,
#          4 secrets-service unreachable or refusing.
# shellcheck shell=bash

# The secrets every installation needs. Nothing starts without them.
RAPIDSELECTOR_SECRETS=(
  POSTGRES_PASSWORD
  LITELLM_MASTER_KEY
  LITELLM_SALT_KEY
  LITELLM_UI_PASSWORD
  RAPIDSELECTOR_OPENROUTER_KEY
  WEBUI_SECRET_KEY
  KEY_CHAT
  KEY_NODE_RED
  KEY_SMOKE_TEST
  KEY_SCRIPTS
)

# Optional secrets: loaded when set, never required to start. The scripts that use one check
# for it themselves. Without the management key, status.sh and reconcile.sh exit 3; the rest
# of the system works (docs: scripts/README.md, "Without the management key").
RAPIDSELECTOR_OPTIONAL_SECRETS=(
  OPENROUTER_MANAGEMENT_KEY
)

# The settings every home's config/home.env must hold (config/home.example.env explains each).
# The rules check (scripts/check-prices.sh) checks them; scripts/setup-keys.sh reads them.
RAPIDSELECTOR_HOME_SETTINGS=(
  BUDGET_TEAM_PERMANENT
  BUDGET_TEAM_EXPERIMENTS
  BUDGET_KEY_NODE_RED
  BUDGET_KEY_SMOKE_TEST
  NODE_RED_RPM
  NODE_RED_TPM
  ALLOWED_HOSTS
)

# die <exit_code> <message>
die() {
  echo "rapidselector: $2" >&2
  exit "$1"
}

# require_env <name...>: exit 3 naming the first variable that is unset or empty.
require_env() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || die 3 "missing value for $name"
  done
}

# load_env_file <file>: export KEY=VALUE lines literally, without shell evaluation.
# A variable already set in the environment wins, as it does for docker compose.
load_env_file() {
  local file="$1" line key value
  [ -f "$file" ] || die 2 "settings file not found: $file (copy .env.example to .env)"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    [ -n "${!key+set}" ] && continue
    export "$key=$value"
  done < "$file"
}

# set_config_paths <repo root>: set GATEWAY_CONFIG and HOME_ENV, this home's config/gateway.yaml
# and config/home.env. RAPIDSELECTOR_GATEWAY_CONFIG and RAPIDSELECTOR_HOME_ENV override them, for
# the tests only (tests/helpers.bash points them at the example files).
set_config_paths() {
  GATEWAY_CONFIG="${RAPIDSELECTOR_GATEWAY_CONFIG:-$1/config/gateway.yaml}"
  HOME_ENV="${RAPIDSELECTOR_HOME_ENV:-$1/config/home.env}"
}

# home_env_value <file> <NAME>: print NAME's value in the file (empty if absent), from the file
# alone: a value already in the environment does not count.
home_env_value() {
  (
    unset "$2"
    load_env_file "$1"
    printf '%s\n' "${!2:-}"
  )
}

# load_secrets_from_service: fetch the secret "rapidselector" and export each required field.
load_secrets_from_service() {
  require_env SECRETS_SERVICE_URL SECRETS_SERVICE_TOKEN_FILE
  [ -r "$SECRETS_SERVICE_TOKEN_FILE" ] || die 4 "cannot read the secrets-service token file $SECRETS_SERVICE_TOKEN_FILE"
  local token response http_status body name value
  token="$(tr -d '[:space:]' < "$SECRETS_SERVICE_TOKEN_FILE")"
  if ! response="$(curl -sS --max-time 15 -w '\n%{http_code}' \
      -H "Authorization: Bearer $token" "$SECRETS_SERVICE_URL/secrets/rapidselector" 2>/dev/null)"; then
    die 4 "secrets-service unreachable at $SECRETS_SERVICE_URL"
  fi
  http_status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  [ "$http_status" = "200" ] || die 4 "secrets-service returned HTTP $http_status for the secret rapidselector"
  jq -e '.blob | type == "object"' <<<"$body" >/dev/null 2>&1 \
    || die 4 "secrets-service returned no fields for the secret rapidselector"
  for name in "${RAPIDSELECTOR_SECRETS[@]}"; do
    value="$(jq -r --arg k "$name" '.blob[$k] // empty' <<<"$body")"
    [ -n "$value" ] || die 3 "the secret rapidselector has no field $name"
    export "$name=$value"
  done
  # Optional secrets only for run-script, the only command whose scripts use them.
  [ "${1:-}" = "with-optional" ] || return 0
  for name in "${RAPIDSELECTOR_OPTIONAL_SECRETS[@]}"; do
    value="$(jq -r --arg k "$name" '.blob[$k] // empty' <<<"$body")"
    export "$name=$value"
  done
}

# load_settings_and_secrets [with-optional]: read the settings file, then the secrets from the
# configured source; the optional ones from secrets-service only with "with-optional" (in env
# mode every line of .env is read anyway, and docker compose reads .env itself too).
load_settings_and_secrets() {
  load_env_file "${RAPIDSELECTOR_ENV_FILE:-$RAPIDSELECTOR_ROOT/.env}"
  case "${SECRETS_SOURCE:-env}" in
    env) require_env "${RAPIDSELECTOR_SECRETS[@]}" ;;
    secrets-service) load_secrets_from_service "${1:-}" ;;
    *) die 2 "SECRETS_SOURCE must be env or secrets-service" ;;
  esac
}

# api <method> <path> [json]: call the gateway with the master key; print the body.
# Returns non-zero on HTTP >= 400 and prints the status to stderr.
# The key goes in as a header file and the body on stdin, so neither is in the process list.
api() {
  local method="$1" path="$2" data="${3:-}" response http_status
  local args=(-sS -X "$method" -w '\n%{http_code}')
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' --data-binary @-)
  response="$(printf '%s' "$data" | curl "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$LITELLM_MASTER_KEY") \
    "http://${RAPIDSELECTOR_LAN_ADDRESS}:${GATEWAY_PORT}${path}")" || return 1
  http_status="${response##*$'\n'}"
  printf '%s\n' "${response%$'\n'*}"
  if [ "$http_status" -ge 400 ]; then
    echo "rapidselector: $method $path returned HTTP $http_status" >&2
    return 1
  fi
}

# inference_key_hash <GET /api/v1/keys answer>: print the hash of the key named
# $OPENROUTER_INFERENCE_KEY_NAME (default rapidselector-gateway). Returns 1, saying why on
# stderr, when no key or more than one key has that name.
inference_key_hash() {
  local name="${OPENROUTER_INFERENCE_KEY_NAME:-rapidselector-gateway}" hashes count
  hashes="$(NAME="$name" jq -r '.data[] | select(.name == env.NAME) | .hash' <<<"$1")" || return 1
  count="$(grep -c . <<<"$hashes" || true)"
  if [ "$count" -eq 1 ]; then
    printf '%s\n' "$hashes"
    return 0
  fi
  if [ "$count" -eq 0 ]; then
    echo "rapidselector: no key named $name in OpenRouter's key list" >&2
  else
    echo "rapidselector: $count keys named $name in OpenRouter's key list: give the gateway's key a name of its own" >&2
  fi
  return 1
}

# read_url <url> <key> <source name>: GET with the key as a header file, so it is in no process
# list or URL; print the body. Returns 1 on no answer or HTTP >= 400, saying so on stderr.
read_url() {
  local response http_status
  response="$(curl -sS --max-time 30 -w '\n%{http_code}' -H @<(printf 'Authorization: Bearer %s\n' "$2") "$1" 2>/dev/null)" \
    || response=$'\n000'
  http_status="${response##*$'\n'}"
  if [ "$http_status" = "000" ]; then
    echo "rapidselector: $3 did not answer (${1%%\?*})" >&2
    return 1
  fi
  if [ "$http_status" = "401" ] && [ "$3" = "OpenRouter" ]; then
    echo "rapidselector: OpenRouter: management key rejected (expired?)" >&2
    return 1
  fi
  if [ "$http_status" -ge 400 ]; then
    echo "rapidselector: $3 answered HTTP $http_status for ${1%%\?*}" >&2
    return 1
  fi
  printf '%s\n' "${response%$'\n'*}"
}

# gw_read <path>: GET on the gateway with KEY_SCRIPTS; see read_url.
gw_read() {
  read_url "http://${RAPIDSELECTOR_LAN_ADDRESS}:${GATEWAY_PORT}$1" "$KEY_SCRIPTS" "the gateway"
}

# or_read <path>: GET on OpenRouter's API (OPENROUTER_API_BASE_URL, for tests) with
# OPENROUTER_MANAGEMENT_KEY; see read_url.
or_read() {
  read_url "${OPENROUTER_API_BASE_URL:-https://openrouter.ai/api/v1}$1" "$OPENROUTER_MANAGEMENT_KEY" "OpenRouter"
}

# require_management_key <script name>: exit 3, saying what is lost and where to read more,
# when the optional OPENROUTER_MANAGEMENT_KEY is not set.
require_management_key() {
  [ -n "${OPENROUTER_MANAGEMENT_KEY:-}" ] \
    || die 3 "no OPENROUTER_MANAGEMENT_KEY: $1 needs the management key, which is optional; see scripts/README.md, \"Without the management key\""
}
