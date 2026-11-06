# Shared helpers for rapidselector.sh and the scripts in scripts/. Source, do not run.
# shellcheck shell=bash

# The secrets every installation needs. The only list of their names.
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
  TOWER_PASSWORD
  TOWER_SESSION_SECRET
  OPENROUTER_MANAGEMENT_KEY
  TOWER_GATEWAY_KEY
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
  for name in "${RAPIDSELECTOR_SECRETS[@]}"; do
    value="$(jq -r --arg k "$name" '.blob[$k] // empty' <<<"$body")"
    [ -n "$value" ] || die 3 "the secret rapidselector has no field $name"
    export "$name=$value"
  done
}

# load_settings_and_secrets: read the settings file, then the secrets from the configured source.
load_settings_and_secrets() {
  load_env_file "${RAPIDSELECTOR_ENV_FILE:-$RAPIDSELECTOR_ROOT/.env}"
  case "${SECRETS_SOURCE:-env}" in
    env) require_env "${RAPIDSELECTOR_SECRETS[@]}" ;;
    secrets-service) load_secrets_from_service ;;
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
