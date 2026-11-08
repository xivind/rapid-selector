#!/usr/bin/env bash
# ONE-OFF, for docs/test-procedures/ops-scripts.md (step A3); deleted from the repository once
# the owner has run it. Moves the secrets from tower's to the scripts': adds KEY_SCRIPTS
# (generated) and removes TOWER_PASSWORD, TOWER_SESSION_SECRET and TOWER_GATEWAY_KEY, keeping
# every other field unchanged. Safe to run twice.
# Run:     scripts/cleanup-tower-secrets.sh, on the host, not through rapidselector.sh (which
#          needs KEY_SCRIPTS to exist already).
#          With SECRETS_SOURCE=secrets-service it changes the secret "rapidselector". With
#          SECRETS_SOURCE=env it changes nothing and prints which .env lines to add and delete.
# Secrets: the secrets-service token (SECRETS_SERVICE_TOKEN_FILE). Prints names and lengths only.
# Cost:    nothing.
# Exit:    0 done or nothing to change, 2 no settings file or a wrong SECRETS_SOURCE, 3 a missing
#          setting, 4 secrets-service unreachable or refusing, or fewer than 9 fields (refused,
#          nothing written).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/scripts/lib.sh"

TOWER_FIELDS=(TOWER_PASSWORD TOWER_SESSION_SECRET TOWER_GATEWAY_KEY)
env_file="${RAPIDSELECTOR_ENV_FILE:-$ROOT/.env}"
load_env_file "$env_file"

case "${SECRETS_SOURCE:-env}" in
  env)
    echo "SECRETS_SOURCE is env: nothing was changed. Edit $env_file by hand:"
    if [ -z "${KEY_SCRIPTS:-}" ]; then
      echo "  add     KEY_SCRIPTS=<value>   make the value with: echo \"sk-\$(openssl rand -hex 24)\""
    fi
    grep -oE '^TOWER_[A-Z_]+=' "$env_file" | tr -d '=' | sed 's/^/  delete  /' || true
    [ -n "${KEY_SCRIPTS:-}" ] || exit 0
    grep -qE '^TOWER_[A-Z_]+=' "$env_file" || echo "  nothing to change."
    exit 0
    ;;
  secrets-service) ;;
  *) die 2 "SECRETS_SOURCE must be env or secrets-service" ;;
esac

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

new="$blob"
if [ -z "$(jq -r '.KEY_SCRIPTS // empty' <<<"$new")" ]; then
  # The value goes to jq through its environment and the blob through stdin, never through argv.
  new="$(V="sk-$(openssl rand -hex 24)" jq -c '. + {KEY_SCRIPTS: env.V}' <<<"$new")"
fi
for name in "${TOWER_FIELDS[@]}"; do
  new="$(jq -c --arg k "$name" 'del(.[$k])' <<<"$new")"
done

if [ "$new" = "$blob" ]; then
  echo "nothing to change. Names and lengths in the secret rapidselector:"
else
  status="$(jq -c '{blob: .}' <<<"$new" \
    | curl -sS --max-time 15 -o /dev/null -w '%{http_code}' -X PUT -H "@$header_file" -H 'Content-Type: application/json' --data @- "$url")" \
    || die 4 "secrets-service unreachable at $SECRETS_SERVICE_URL"
  [ "$status" = "200" ] || die 4 "secrets-service returned HTTP $status when storing the secret"
  echo "stored. Names and lengths now in the secret rapidselector:"
fi
curl -sS --max-time 15 -H "@$header_file" "$url" | jq -r '.blob | to_entries[] | "\(.key) \(.value | length)"'
