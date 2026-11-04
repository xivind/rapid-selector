#!/usr/bin/env bash
# Compare every entry in the gateway config with OpenRouter's public list of zero data
# retention endpoints: the pinned endpoint must exist, not be in the flex tier, not use Safety
# Retention (the list includes those), and have the configured input and output price. Free; run before every change to the allowlist.
# Usage: tests/check-prices.sh [config file]  (default: gateway/config.yaml)
# The parser expects the layout of gateway/config.yaml: model_name, then litellm_params with
# model, the two prices and provider.order, in that order within each entry.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-$repo/gateway/config.yaml}"

# ZDR_ENDPOINTS_FILE: a saved copy of the endpoint list, for the tests; normally fetched live.
if [ -n "${ZDR_ENDPOINTS_FILE:-}" ]; then
  endpoints="$(cat "$ZDR_ENDPOINTS_FILE")"
else
  endpoints="$(curl -sS --max-time 60 https://openrouter.ai/api/v1/endpoints/zdr)" \
    || { echo "cannot reach OpenRouter's API"; exit 2; }
fi

mapfile -t entries < <(awk '
  /^[[:space:]]*- model_name:/ { if (name != "") print name, model, input, output, slug; name = $3; model = input = output = slug = "-" }
  /^[[:space:]]*model: openrouter\// { model = substr($2, 12) }
  /^[[:space:]]*input_cost_per_token:/ { input = $2 }
  /^[[:space:]]*output_cost_per_token:/ { output = $2 }
  /^[[:space:]]*order:/ { s = $2; gsub(/[\[\]"]/, "", s); slug = s }
  END { if (name != "") print name, model, input, output, slug }
' "$config")

failed=0
for entry in "${entries[@]}"; do
  read -r name model input output slug <<<"$entry"
  match="$(jq -c --arg m "$model" --arg s "$slug" '[.data[] | select(.model_id == $m and .tag == $s)][0] // empty' <<<"$endpoints")"
  if [ -z "$match" ]; then
    echo "FAIL $name: no zero data retention endpoint $slug for $model"
    failed=1
    continue
  fi
  verdict="$(jq -r --argjson i "$input" --argjson o "$output" '
    def close(a; b): ((a - b) | fabs) < 1e-15;
    if .service_tier == "flex" then "flex tier"
    elif .safety_retention == true then "uses Safety Retention, not zero data retention"
    elif (close(.pricing.prompt | tonumber; $i) | not) or (close(.pricing.completion | tonumber; $o) | not)
    then "price is now \(.pricing.prompt) / \(.pricing.completion) per token, configured \($i) / \($o)"
    else "ok" end' <<<"$match" 2>/dev/null || echo "missing price in the config")"
  if [ "$verdict" = "ok" ]; then
    echo "ok $name ($slug)"
  else
    echo "FAIL $name ($slug): $verdict"
    failed=1
  fi
done
exit "$failed"
