#!/usr/bin/env bash
# Add tower's four secrets to the secret "rapidselector" in secrets-service, keeping every
# field already there. Fields that already exist are never changed, so it is safe to run again.
# Generates TOWER_PASSWORD, TOWER_SESSION_SECRET and TOWER_GATEWAY_KEY, and asks for the
# OpenRouter management key (typed or pasted invisibly, never shown). Prints names and lengths only.
# Run on the host, not through rapidselector.sh (that needs these secrets to exist already):
#   scripts/add-tower-secrets.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/scripts/lib.sh"

load_env_file "$ROOT/.env"
[ "${SECRETS_SOURCE:-env}" = "secrets-service" ] || die 2 "SECRETS_SOURCE is not secrets-service: add the four values to .env by hand (README, step 3)"
require_env SECRETS_SERVICE_URL SECRETS_SERVICE_TOKEN_FILE
[ -r "$SECRETS_SERVICE_TOKEN_FILE" ] || die 4 "cannot read the token file $SECRETS_SERVICE_TOKEN_FILE"

url="$SECRETS_SERVICE_URL/secrets/rapidselector"
# The header goes through a private file, so the token never appears in a process list.
umask 077
header_file="$(mktemp)"
trap 'rm -f "$header_file"' EXIT
printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$SECRETS_SERVICE_TOKEN_FILE")" > "$header_file"

response="$(curl -sS --max-time 15 -w '\n%{http_code}' -H "@$header_file" "$url")" || die 4 "secrets-service unreachable at $SECRETS_SERVICE_URL"
[ "${response##*$'\n'}" = "200" ] || die 4 "secrets-service returned HTTP ${response##*$'\n'} for the secret rapidselector"
blob="$(jq -c '.blob' <<<"${response%$'\n'*}")"
[ "$(jq 'length' <<<"$blob")" -ge 9 ] || die 4 "the secret rapidselector has fewer than 9 fields: refusing to write"

has() { [ -n "$(jq -r --arg k "$1" '.[$k] // empty' <<<"$blob")" ]; }
# The value goes to jq through its environment and the blob through stdin, never through argv.
add() { blob="$(V="$2" jq -c --arg k "$1" '. + {($k): env.V}' <<<"$blob")"; }

has TOWER_PASSWORD || add TOWER_PASSWORD "$(openssl rand -hex 16)"
has TOWER_SESSION_SECRET || add TOWER_SESSION_SECRET "$(openssl rand -hex 32)"
has TOWER_GATEWAY_KEY || add TOWER_GATEWAY_KEY "sk-$(openssl rand -hex 24)"
if ! has OPENROUTER_MANAGEMENT_KEY; then
  read -rsp "OpenRouter management key (nothing is shown): " mgmt
  echo
  [ -n "$mgmt" ] || die 2 "no key entered: nothing was written"
  add OPENROUTER_MANAGEMENT_KEY "$mgmt"
  unset mgmt
fi

status="$(jq -c '{blob: .}' <<<"$blob" \
  | curl -sS --max-time 15 -o /dev/null -w '%{http_code}' -X PUT -H "@$header_file" -H 'Content-Type: application/json' --data @- "$url")" \
  || die 4 "secrets-service unreachable at $SECRETS_SERVICE_URL"
[ "$status" = "200" ] || die 4 "secrets-service returned HTTP $status when storing the secret"

echo "stored. Names and lengths now in the secret rapidselector:"
curl -sS --max-time 15 -H "@$header_file" "$url" | jq -r '.blob | to_entries[] | "\(.key) \(.value | length)"'
