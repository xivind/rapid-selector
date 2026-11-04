#!/usr/bin/env bash
# Test A (phase 0, level 3): use up the OpenRouter balance on purpose, to see what happens at
# zero. Run it only while being walked through docs/test-procedures/phase-0.md. It spends
# real money: up to --max-usd.
#
#   ./rapidselector.sh run-script scripts/drain-balance.sh --max-usd <amount> [--max-calls N]
#
# Creates a temporary key "drain-test" (deleted on every exit), calls the most expensive
# allowlisted model one call at a time until the first refusal, then sends 5 calls at once.
# Stops early at --max-calls (default 500) or when the cost of the calls reaches --max-usd.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/scripts/lib.sh"

MODEL="qwen3.8-2.4t-a95b@siliconflow"
MAX_TOKENS=8192
max_usd=""
max_calls=500
while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-usd) max_usd="${2:-}"; shift 2 ;;
    --max-calls) max_calls="${2:-}"; shift 2 ;;
    *) die 2 "usage: drain-balance.sh --max-usd <amount> [--max-calls N]" ;;
  esac
done
[[ "$max_usd" =~ ^[0-9]+([.][0-9]+)?$ ]] || die 2 "usage: drain-balance.sh --max-usd <amount> [--max-calls N]"
[[ "$max_calls" =~ ^[0-9]+$ ]] || die 2 "--max-calls must be a whole number"
require_env LITELLM_MASTER_KEY RAPIDSELECTOR_LAN_ADDRESS GATEWAY_PORT
GATEWAY="http://${RAPIDSELECTOR_LAN_ADDRESS}:${GATEWAY_PORT}"

cat <<EOF
Test A: use up the OpenRouter balance.
  Model:      $MODEL, max_tokens $MAX_TOKENS, one call at a time
  Stops at:   the first refusal (then 5 calls at once), $max_calls calls, or \$$max_usd spent
  This spends real money, up to \$$max_usd.
Type drain to start:
EOF
answer=""
read -r answer || true
[ "$answer" = "drain" ] || die 1 "not confirmed; nothing was called"

key=""
# shellcheck disable=SC2329  # called by the EXIT trap below
cleanup() {
  if [ -n "$key" ]; then
    api POST /key/delete "$(jq -nc --arg k "$key" '{keys:[$k]}')" >/dev/null 2>&1 \
      || echo "rapidselector: could not delete the temporary key drain-test; delete it in the admin UI" >&2
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

key="$(api POST /key/generate "$(jq -nc --arg m "$MODEL" --argjson b "$max_usd" \
  '{key_alias:"drain-test", team_id:"experiments", models:[$m], max_budget:$b, budget_duration:"30d",
    allowed_routes:["/v1/chat/completions","/chat/completions"]}')" | jq -r '.key')" \
  || die 1 "could not create the temporary key"

body="$(jq -nc --arg m "$MODEL" --argjson t "$MAX_TOKENS" \
  '{model:$m, max_tokens:$t, messages:[{role:"user",content:"Write a long, detailed essay about the history of microfilm."}]}')"

# call <headers file> <body file>: one call with the temporary key; prints the HTTP status.
call() {
  curl -sS -D "$1" -o "$2" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' -d "$body" || echo 000
}

tmp="$(mktemp -d)"
calls=0
spent=0
reason=""
last=()
while :; do
  status="$(call "$tmp/h" "$tmp/b")"
  cost="$( (grep -i '^x-litellm-response-cost:' "$tmp/h" || true) | tail -1 | cut -d: -f2- | tr -d ' \r')"
  last+=("$status $(head -c 300 "$tmp/b" | tr '\n' ' ')")
  [ "${#last[@]}" -gt 3 ] && last=("${last[@]: -3}")
  if [ "$status" != "200" ]; then
    reason="refused"
    break
  fi
  calls=$((calls + 1))
  spent="$(awk -v s="$spent" -v c="${cost:-0}" 'BEGIN { printf "%.6f", s + c }')"
  if [ "$calls" -ge "$max_calls" ]; then reason="max-calls"; break; fi
  if awk -v s="$spent" -v m="$max_usd" 'BEGIN { exit !(s >= m) }'; then reason="max-usd"; break; fi
done

burst=""
if [ "$reason" = "refused" ]; then
  for i in 1 2 3 4 5; do
    call "$tmp/bh$i" "$tmp/bb$i" > "$tmp/bs$i" &
  done
  wait
  for i in 1 2 3 4 5; do burst+=" $(cat "$tmp/bs$i")"; done
fi

recorded="$(api GET "/key/info?key=$key" 2>/dev/null | jq -r '.info.spend // "unknown"' || echo unknown)"
echo "calls_succeeded $calls"
echo "cost_of_calls_usd $spent"
echo "recorded_spend_usd $recorded"
echo "stopped: $reason"
echo "last answers:"
printf '  %s\n' "${last[@]}"
[ -n "$burst" ] && echo "burst$burst"
rm -rf "$tmp"
exit 0
