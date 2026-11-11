#!/usr/bin/env bash
# For testing only. Tests A and B (phase 0, level 3, D1 and D6): call the most expensive
# allowlisted model until OpenRouter refuses, to see where the key limit or the balance stops
# spend, and whether calls sent at the same time can get past it. Run it only while being
# walked through docs/test-procedures/phase-0.md.
# Run:     ./rapidselector.sh run-script tests/drain-balance.sh --max-usd <amount>
#              [--max-calls N] [--max-tokens N] [--parallel N]
# Secrets: LITELLM_MASTER_KEY (it creates and deletes a temporary key "drain-test").
# Cost:    real money: up to --max-usd, plus the overshoot the test is there to measure.
# Exit:    0 the run ended and printed its result, 1 a setup step failed or not confirmed,
#          2 wrong usage, 3 a missing value, 130 interrupted.
#
# Creates a temporary key "drain-test" (deleted on every exit), then sends rounds of --parallel
# calls at once. A round that could pass --max-usd does not start. --max-calls counts every
# call sent. After each round the most serious answer decides:
#   a fault               stop: error (not a limit result)
#   the gateway's budget  stop: gateway-budget
#   a limit refusal       halve max_tokens; below 16, stop: refused
#   an in-flight refusal  wait and repeat; after 6 rounds with no answer, stop: in-flight
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/../scripts/lib.sh
. "$ROOT/scripts/lib.sh"

MODEL="qwen3.8-2.4t-a95b@siliconflow"
USAGE="usage: drain-balance.sh --max-usd <amount> [--max-calls N] [--max-tokens N] [--parallel N]"
MIN_TOKENS=16
# Worst-case input per call, in tokens: the prompt below is about 20.
PROMPT_MARGIN=100
MAX_QUIET_ROUNDS=6
# The gateway drops OpenRouter's Retry-After, so the wait is fixed. Tests shorten both.
RETRY_WAIT="${DRAIN_RETRY_WAIT:-10}"
# Allows about 10 tokens a second at 8192. A timed-out call may still be charged, uncounted.
CURL_TIMEOUT="${DRAIN_CURL_TIMEOUT:-900}"
SPEND_WAIT=30

max_usd=""
max_calls=500
max_tokens=8192
parallel=5
while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-usd) max_usd="${2:-}"; shift 2 ;;
    --max-calls) max_calls="${2:-}"; shift 2 ;;
    --max-tokens) max_tokens="${2:-}"; shift 2 ;;
    --parallel) parallel="${2:-}"; shift 2 ;;
    *) die 2 "$USAGE" ;;
  esac
done
[[ "$max_usd" =~ ^[0-9]+([.][0-9]+)?$ ]] || die 2 "$USAGE"
[[ "$max_calls" =~ ^[1-9][0-9]*$ ]] || die 2 "--max-calls must be a whole number above zero"
[[ "$max_tokens" =~ ^[1-9][0-9]*$ ]] || die 2 "--max-tokens must be a whole number above zero"
[[ "$parallel" =~ ^[1-9][0-9]*$ ]] || die 2 "--parallel must be a whole number above zero"
require_env LITELLM_MASTER_KEY RAPIDSELECTOR_LAN_ADDRESS GATEWAY_PORT
GATEWAY="http://${RAPIDSELECTOR_LAN_ADDRESS}:${GATEWAY_PORT}"

price="$(api GET /model/info | jq -r --arg m "$MODEL" \
  '[.data[] | select(.model_name == $m) | .model_info.output_cost_per_token][0] // empty')" \
  || die 1 "cannot read /model/info from the gateway"
[ -n "$price" ] || die 1 "no output price for $MODEL in the gateway"

cat <<EOF
Drain test: call until OpenRouter refuses.
  Model:      $MODEL, from max_tokens $max_tokens, $parallel calls at once
  Stops at:   a final refusal, a fault, $max_calls calls, or before a round that could pass \$$max_usd
  This spends real money, up to \$$max_usd.
Type drain to start:
EOF
answer=""
read -r answer || true
[ "$answer" = "drain" ] || die 1 "not confirmed; nothing was called"

key=""
tmp="$(mktemp -d)"
# shellcheck disable=SC2329  # called by the EXIT trap below
cleanup() {
  # shellcheck disable=SC2046  # one process id per word
  kill $(jobs -p) 2>/dev/null || true
  if [ -n "$key" ]; then
    api POST /key/delete "$(jq -nc --arg k "$key" '{keys:[$k]}')" >/dev/null 2>&1 \
      || echo "rapidselector: could not delete the temporary key drain-test; delete it in the admin UI" >&2
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

key="$(api POST /key/generate "$(jq -nc --arg m "$MODEL" --argjson b "$max_usd" \
  '{key_alias:"drain-test", team_id:"experiments", models:[$m], max_budget:$b, budget_duration:"30d",
    allowed_routes:["/v1/chat/completions","/chat/completions"]}')" | jq -r '.key')" \
  || die 1 "could not create the temporary key"

# One call: the HTTP status goes to stdout (curl prints 000 when the connection fails).
CALL=(curl -sS --max-time "$CURL_TIMEOUT" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions"
  -H "Authorization: Bearer $key" -H 'Content-Type: application/json')

# classify <status> <body file> <cost>: prints ok, in-flight, limit, gateway or fault.
# An answer with no cost is a fault: uncounted spend would make --max-usd useless.
classify() {
  if [ "$1" = "200" ]; then
    if awk -v c="${3:-0}" 'BEGIN { exit !(c + 0 > 0) }'; then echo ok; else echo fault; fi
  elif grep -q 'openrouter_in_flight_budget' "$2"; then echo in-flight
  elif [ "$1" = "402" ] || grep -Eq 'openrouter_key_limit|openrouter_credits' "$2"; then echo limit
  elif [ "$1" = "422" ] && grep -q 'budget_exceeded' "$2"; then echo gateway
  else echo fault
  fi
}

sent=0
answered=0
spent=0
tokens="$max_tokens"
round=0
quiet=0
reason=""
last=()
while :; do
  n=$((max_calls - sent))
  [ "$n" -gt "$parallel" ] && n="$parallel"
  if [ "$n" -le 0 ]; then reason="max-calls"; break; fi
  if awk -v s="$spent" -v n="$n" -v t="$tokens" -v g="$PROMPT_MARGIN" -v p="$price" -v m="$max_usd" \
    'BEGIN { exit !(s + n * (t + g) * p > m) }'; then reason="max-usd"; break; fi

  round=$((round + 1))
  body="$(jq -nc --arg m "$MODEL" --argjson t "$tokens" \
    '{model:$m, max_tokens:$t, messages:[{role:"user",content:"Write a long, detailed essay about the history of microfilm."}]}')"
  for ((i = 1; i <= n; i++)); do
    # A failed call leaves these files alone, so empty them: the last round's refusal must not count.
    : > "$tmp/h$i"
    : > "$tmp/b$i"
    "${CALL[@]}" -D "$tmp/h$i" -o "$tmp/b$i" -d "$body" > "$tmp/s$i" &
  done
  wait
  sent=$((sent + n))

  statuses=""
  outcomes=""
  round_answered=0
  for ((i = 1; i <= n; i++)); do
    status="$(cat "$tmp/s$i")"
    statuses+=" $status"
    cost="$( (grep -i '^x-litellm-response-cost:' "$tmp/h$i" || true) | tail -1 | cut -d: -f2- | tr -d ' \r')"
    outcome="$(classify "$status" "$tmp/b$i" "$cost")"
    outcomes+=" $outcome"
    if [ "$status" = "200" ]; then
      round_answered=$((round_answered + 1))
      [ "$outcome" = "ok" ] || last+=("200 with no recorded cost")
      spent="$(awk -v s="$spent" -v c="${cost:-0}" 'BEGIN { printf "%.6f", s + c }')"
    else
      last+=("$status $(head -c 600 "$tmp/b$i" | tr '\n' ' ')")
    fi
    [ "${#last[@]}" -gt 3 ] && last=("${last[@]: -3}")
  done
  answered=$((answered + round_answered))
  echo "round $round: max_tokens $tokens:$statuses, spent $spent"

  case "$outcomes" in
    *fault*) reason="error"; break ;;
    *gateway*) reason="gateway-budget"; break ;;
    *limit*)
      quiet=0
      tokens=$((tokens / 2))
      if [ "$tokens" -lt "$MIN_TOKENS" ]; then reason="refused"; break; fi
      ;;
    *in-flight*)
      if [ "$round_answered" -gt 0 ]; then quiet=0; else quiet=$((quiet + 1)); fi
      if [ "$quiet" -ge "$MAX_QUIET_ROUNDS" ]; then reason="in-flight"; break; fi
      sleep "$RETRY_WAIT"
      ;;
    *) quiet=0 ;;
  esac
done

case "$reason" in
  error) reason+=" (a fault, not a limit: the test did not finish)" ;;
  in-flight) reason+=" (still refused for in-flight requests: the test did not finish)" ;;
  gateway-budget) reason+=" (the gateway's own budget, not OpenRouter's)" ;;
esac

# The gateway writes spend in batches (every 10 seconds), so wait for it after answered calls.
recorded=unknown
for _ in $(seq 1 "$SPEND_WAIT"); do
  recorded="$(api GET "/key/info?key=$key" 2>/dev/null | jq -r '.info.spend // "unknown"' || echo unknown)"
  if [ "$answered" -eq 0 ] || awk -v r="$recorded" -v s="$spent" 'BEGIN { exit !(r + 0 >= s * 0.99) }'; then break; fi
  sleep 1
done
echo "calls_succeeded $answered"
echo "calls_sent $sent"
echo "cost_of_calls_usd $spent"
echo "recorded_spend_usd $recorded"
echo "stopped: $reason"
echo "last refusals:"
[ "${#last[@]}" -eq 0 ] || printf '  %s\n' "${last[@]}"
exit 0
