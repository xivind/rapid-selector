#!/usr/bin/env bash
# Call the role "classify" with the master key every few seconds and print the time, the HTTP
# status and the start of any error, to see when a change (such as the OpenRouter key being
# disabled by the kill switch) starts or stops refusing calls. Used by step E2 of
# docs/test-procedures/tower-1a.md. Stop with Ctrl-C.
# Run with the secrets loaded:   ./rapidselector.sh run-script scripts/probe-key.sh [--max-calls N]
# Costs nothing while calls are refused, and under $0.00001 for each call that is answered.
# Upper limit: 100 calls (--max-calls can only lower it), one call every 3 seconds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/scripts/lib.sh"

max_calls=100
if [ "${1:-}" = "--max-calls" ]; then
  [ -n "${2:-}" ] && [ "$2" -ge 1 ] && [ "$2" -le 100 ] || die 2 "--max-calls takes a number from 1 to 100"
  max_calls="$2"
fi

require_env LITELLM_MASTER_KEY RAPIDSELECTOR_LAN_ADDRESS GATEWAY_PORT
GATEWAY="http://$RAPIDSELECTOR_LAN_ADDRESS:$GATEWAY_PORT"
body='{"model":"classify","max_tokens":5,"messages":[{"role":"user","content":"Reply with the word ok."}]}'
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

for ((i = 1; i <= max_calls; i++)); do
  status="$(curl -sS -m 30 -o "$out" -w '%{http_code}' -X POST "$GATEWAY/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' -d "$body" || echo 000)"
  msg=""
  if [ "$status" != "200" ]; then
    msg="$(jq -r '.error.message // empty' "$out" 2> /dev/null | tr '\n' ' ' | cut -c1-100 || true)"
  fi
  printf '%s %s %s\n' "$(date -u +%H:%M:%S)" "$status" "$msg"
  sleep 3
done
echo "stopped: --max-calls $max_calls reached"
