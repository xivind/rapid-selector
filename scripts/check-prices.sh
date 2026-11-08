#!/usr/bin/env bash
# Check every entry in the gateway config in two parts, so a model change cannot break
# CLAUDE.md's principles 1 and 4 or record the wrong spend:
# 1. The rules, offline: provider.order and provider.only name the same single endpoint, at
#    one of the account's allowed providers (ALLOWED_HOSTS below); allow_fallbacks false; zdr
#    true; data_collection deny; a max_tokens; both prices above zero; no :free model and no
#    wildcard. A field the parser cannot read fails as "cannot read <field>".
# 2. The prices, online, against OpenRouter's public list of zero data retention endpoints:
#    the pinned endpoint must exist, not be in the flex tier, not use Safety Retention (the
#    list includes those), and have the configured input and output price.
# Run it before every change to the allowlist; prices at a host change without notice.
# `./rapidselector.sh restart gateway` runs part 1 on its own first.
# Run:     scripts/check-prices.sh [--rules-only] [config file]  (default: gateway/config.yaml),
#          on the host
# Secrets: none (OpenRouter's list is public).
# Cost:    nothing.
# Exit:    0 every entry passes, 1 an entry fails (one FAIL line each), 2 OpenRouter's list
#          cannot be read (never with --rules-only).
# The parser expects the layout of gateway/config.yaml: one "- model_name:" line per entry,
# then its fields one per line (model, max_tokens, the two prices, and under provider: order,
# only, allow_fallbacks, zdr, data_collection).
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
# The account's allowed providers in OpenRouter's settings (the tag before the "/").
ALLOWED_HOSTS="cloudflare coreweave deepinfra siliconflow"

rules_only=0
if [ "${1:-}" = "--rules-only" ]; then rules_only=1; shift; fi
config="${1:-$repo/gateway/config.yaml}"
[ -r "$config" ] || { echo "cannot read $config"; exit 2; }

# One line per entry: name model input output order only max_tokens allow_fallbacks zdr
# data_collection. A field not found stays "-"; order and only lose brackets, quotes and spaces.
mapfile -t entries < <(awk '
  function out() { if (name != "") print name, model, input, output, order, only, maxt, fb, zdr, dc }
  function val() { return ($2 == "" ? "-" : $2) }
  function list(  s) { s = $0; sub(/^[^:]*:/, "", s); gsub(/[][" ]/, "", s); return (s == "" ? "-" : s) }
  /^[[:space:]]*- model_name:/ { out(); name = ($3 == "" ? "-" : $3); model = input = output = order = only = maxt = fb = zdr = dc = "-" }
  /^[[:space:]]*model: openrouter\// { model = substr($2, 12) }
  /^[[:space:]]*input_cost_per_token:/ { input = val() }
  /^[[:space:]]*output_cost_per_token:/ { output = val() }
  /^[[:space:]]*max_tokens:/ { maxt = val() }
  /^[[:space:]]*order:/ { order = list() }
  /^[[:space:]]*only:/ { only = list() }
  /^[[:space:]]*allow_fallbacks:/ { fb = val() }
  /^[[:space:]]*zdr:/ { zdr = val() }
  /^[[:space:]]*data_collection:/ { dc = val() }
  END { out() }
' "$config")

# rule_failures <entry fields...>: one reason per broken rule, or nothing.
rule_failures() {
  local name="$1" model="$2" input="$3" output="$4" order="$5" only="$6" maxt="$7" fb="$8" zdr="$9" dc="${10}"
  local field value
  for field in model input_cost_per_token output_cost_per_token order only max_tokens allow_fallbacks zdr data_collection; do
    case "$field" in
      model) value="$model" ;; input_cost_per_token) value="$input" ;; output_cost_per_token) value="$output" ;;
      order) value="$order" ;; only) value="$only" ;; max_tokens) value="$maxt" ;;
      allow_fallbacks) value="$fb" ;; zdr) value="$zdr" ;; data_collection) value="$dc" ;;
    esac
    [ "$value" != "-" ] || echo "cannot read $field"
  done
  [[ "$name$model" != *"*"* ]] || echo "a wildcard model is not allowed"
  [[ "$model" != *:free ]] || echo "a :free model is not allowed"
  for field in input_cost_per_token output_cost_per_token; do
    [ "$field" = input_cost_per_token ] && value="$input" || value="$output"
    [ "$value" = "-" ] || awk -v v="$value" 'BEGIN { exit !(v ~ /^[0-9.]+([eE]-?[0-9]+)?$/ && v + 0 > 0) }' \
      || echo "$field must be above zero"
  done
  [ "$maxt" = "-" ] || [[ "$maxt" =~ ^[1-9][0-9]*$ ]] || echo "max_tokens must be a whole number above zero"
  if [ "$order" != "-" ]; then
    if [[ "$order" == *,* ]]; then
      echo "order must name exactly one endpoint"
    elif [[ " $ALLOWED_HOSTS " != *" ${order%%/*} "* ]]; then
      echo "host ${order%%/*} is not an allowed provider"
    fi
  fi
  [ "$order" = "-" ] || [ "$only" = "-" ] || [ "$only" = "$order" ] || echo "only must equal order"
  [ "$fb" = "-" ] || [ "$fb" = "false" ] || echo "allow_fallbacks must be false"
  [ "$zdr" = "-" ] || [ "$zdr" = "true" ] || echo "zdr must be true"
  [ "$dc" = "-" ] || [ "$dc" = "deny" ] || echo "data_collection must be deny"
}

failed=0
[ "${#entries[@]}" -gt 0 ] || { echo "FAIL $config: no entries found"; exit 1; }
for entry in "${entries[@]}"; do
  read -r -a fields <<<"$entry"
  while IFS= read -r reason; do
    [ -n "$reason" ] || continue
    echo "FAIL ${fields[0]}: $reason"
    failed=1
  done < <(rule_failures "${fields[@]}")
done
[ "$failed" -eq 1 ] || echo "rules ok: ${#entries[@]} entries"
[ "$rules_only" -eq 0 ] || exit "$failed"

# ZDR_ENDPOINTS_FILE: a saved copy of the endpoint list, for the tests; normally fetched live.
if [ -n "${ZDR_ENDPOINTS_FILE:-}" ]; then
  endpoints="$(cat "$ZDR_ENDPOINTS_FILE")"
else
  endpoints="$(curl -sS --max-time 60 https://openrouter.ai/api/v1/endpoints/zdr)" \
    || { echo "cannot reach OpenRouter's API"; exit 2; }
fi

for entry in "${entries[@]}"; do
  read -r name model input output slug _ <<<"$entry"
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
