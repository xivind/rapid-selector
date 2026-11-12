#!/usr/bin/env bash
# Smoke test: one tiny call per role (per name with --all, or one name with --name) with
# the smoke-test key. Each call must be answered and recorded with a cost above zero; a model
# outside the allowlist and the /openrouter pass-through must be refused. Run it after
# setup-keys.sh, and after every model change.
# Run:     ./rapidselector.sh run-script scripts/smoke-test.sh [--all | --name <name>]
# Secrets: LITELLM_MASTER_KEY (to read the names), KEY_SMOKE_TEST (to call them).
# Cost:    a little real money against OpenRouter: well under $0.01 for the roles; more with
#          --all, which calls every name including the largest models.
# Exit:    0 every check passed, 1 a check failed or wrong usage, 3 a missing value.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/scripts/lib.sh"

require_env LITELLM_MASTER_KEY KEY_SMOKE_TEST RAPIDSELECTOR_LAN_ADDRESS GATEWAY_PORT
GATEWAY="http://${RAPIDSELECTOR_LAN_ADDRESS}:${GATEWAY_PORT}"

only=""
case "${1:-}" in
  "") filter='.data[] | select(.model_info.rapidselector_kind == "role")' ;;
  --all) filter='.data[]' ;;
  --name)
    only="${2:-}"
    [ -n "$only" ] || die 1 "--name needs a name, e.g. --name chat-tasks"
    filter='.data[] | select(.model_name == $only)'
    ;;
  *) die 1 "unknown option: $1 (use --all or --name <name>)" ;;
esac

model_info="$(api GET /model/info)" || die 1 "cannot read /model/info from the gateway"
mapfile -t entries < <(jq -r --arg only "$only" "[$filter | {n: .model_name, r: (.model_info.reasoning == true)}] | unique_by(.n) | .[] | \"\(.n) \(.r)\"" <<<"$model_info")
[ -z "$only" ] || [ "${#entries[@]}" -gt 0 ] || die 1 "the gateway has no name $only"

failures=()
total=0

# status_of <path> <json>: HTTP status of a POST with the smoke-test key.
status_of() {
  curl -sS -o /dev/null -w '%{http_code}' -X POST "$GATEWAY$1" \
    -H "Authorization: Bearer $KEY_SMOKE_TEST" -H 'Content-Type: application/json' -d "$2"
}

for entry in "${entries[@]}"; do
  name="${entry% *}"
  reasoning="${entry#* }"
  body="$(jq -nc --arg m "$name" '{model:$m, max_tokens:256, messages:[{role:"user",content:"Reply with the word ok."}]}')"
  [ "$reasoning" = "true" ] && body="$(jq -c '. + {reasoning_effort:"low"}' <<<"$body")"
  headers="$(mktemp)"
  http_status="$(curl -sS -D "$headers" -o /dev/null -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $KEY_SMOKE_TEST" -H 'Content-Type: application/json' -d "$body" || echo 000)"
  # No cost header (spend not recorded) counts as cost 0.
  cost="$( (grep -i '^x-litellm-response-cost:' "$headers" || true) | tail -1 | cut -d: -f2- | tr -d ' \r')"
  rm -f "$headers"
  cost="$(awk -v c="${cost:-0}" 'BEGIN { printf "%.8f", c + 0 }')"
  printf '%-32s %s %s\n' "$name" "$http_status" "$cost"
  if [ "$http_status" != "200" ]; then
    failures+=("$name: HTTP $http_status")
  elif awk -v c="$cost" 'BEGIN { exit !(c <= 0) }'; then
    failures+=("$name: recorded cost is zero")
  fi
  total="$(awk -v t="$total" -v c="$cost" 'BEGIN { printf "%.8f", t + c }')"
done

probe='{"model":"openai/gpt-4o","messages":[{"role":"user","content":"hi"}]}'
code="$(status_of /v1/chat/completions "$probe")"
if [ "$code" -ge 400 ] && [ "$code" -lt 500 ]; then echo "refused: openai/gpt-4o ($code)"; else failures+=("openai/gpt-4o was not refused: HTTP $code"); fi
probe='{"model":"chat-tasks","messages":[{"role":"user","content":"hi"}]}'
code="$(status_of /openrouter/v1/chat/completions "$probe")"
if [ "$code" = "401" ] || [ "$code" = "403" ]; then echo "refused: /openrouter/v1/chat/completions ($code)"; else failures+=("/openrouter/v1/chat/completions was not refused: HTTP $code"); fi

echo "total_usd $total"
if [ "${#failures[@]}" -gt 0 ]; then
  echo "FAILED:"
  printf '  %s\n' "${failures[@]}"
  exit 1
fi
echo "OK"
