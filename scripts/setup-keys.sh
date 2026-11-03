#!/usr/bin/env bash
# Create or update the teams and virtual keys in the gateway. Safe to run again: it creates
# what is missing and resets budgets, allowed names, rate limits and routes to the values here.
# Run with the secrets loaded:   ./rapidselector.sh run-script scripts/setup-keys.sh
#
# Budgets (USD, reset on the 1st of the month, 00:00 UTC). The BUDGET_* overrides exist only
# for the level 1 tests; normal use never sets them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/scripts/lib.sh"

BUDGET_TEAM_PERMANENT="${BUDGET_TEAM_PERMANENT:-8}"
BUDGET_TEAM_EXPERIMENTS="${BUDGET_TEAM_EXPERIMENTS:-24}"
BUDGET_KEY_NODE_RED="${BUDGET_KEY_NODE_RED:-4}"
BUDGET_KEY_SMOKE_TEST="${BUDGET_KEY_SMOKE_TEST:-1}"
BUDGET_DURATION="30d"
NODE_RED_RPM=30
# Virtual keys may only call chat completions and list models: no pass-through or admin routes.
ALLOWED_ROUTES='["/v1/chat/completions","/chat/completions","/v1/models","/models"]'

require_env LITELLM_MASTER_KEY RAPIDSELECTOR_LAN_ADDRESS GATEWAY_PORT KEY_CHAT KEY_NODE_RED KEY_SMOKE_TEST

model_info="$(api GET /model/info)" || die 1 "cannot read /model/info from the gateway"
ALL_NAMES="$(jq -c '[.data[].model_name] | unique' <<<"$model_info")"
ROLES="$(jq -c '[.data[] | select(.model_info.rapidselector_kind == "role") | .model_name] | unique' <<<"$model_info")"
[ "$(jq length <<<"$ROLES")" -gt 0 ] || die 1 "no entry of kind role in gateway/config.yaml"

# ensure_team <team_id> <max_budget> <models json>
ensure_team() {
  local payload
  payload="$(jq -nc --arg id "$1" --argjson b "$2" --argjson m "$3" --arg d "$BUDGET_DURATION" \
    '{team_id:$id, team_alias:$id, models:$m, max_budget:$b, budget_duration:$d}')"
  if api GET "/team/info?team_id=$1" >/dev/null 2>&1; then
    api POST /team/update "$payload" >/dev/null || die 1 "could not update team $1"
  else
    api POST /team/new "$payload" >/dev/null || die 1 "could not create team $1"
  fi
}

# ensure_key <alias> <key value> <team_id> <max_budget or null> <models json> <rpm_limit or null>
ensure_key() {
  local duration=null payload
  [ "$4" != "null" ] && duration="\"$BUDGET_DURATION\""
  payload="$(jq -nc --arg a "$1" --arg k "$2" --arg t "$3" --argjson b "$4" --argjson m "$5" \
    --argjson r "$6" --argjson d "$duration" --argjson routes "$ALLOWED_ROUTES" \
    '{key:$k, key_alias:$a, team_id:$t, models:$m, max_budget:$b, budget_duration:$d, rpm_limit:$r, allowed_routes:$routes}')"
  if api GET "/key/info?key=$2" >/dev/null 2>&1; then
    api POST /key/update "$payload" >/dev/null || die 1 "could not update key $1"
  else
    api POST /key/generate "$payload" >/dev/null || die 1 "could not create key $1"
  fi
}

ensure_team permanent "$BUDGET_TEAM_PERMANENT" "$ROLES"
ensure_team experiments "$BUDGET_TEAM_EXPERIMENTS" "$ALL_NAMES"
ensure_key node-red "$KEY_NODE_RED" permanent "$BUDGET_KEY_NODE_RED" "$ROLES" "$NODE_RED_RPM"
ensure_key chat "$KEY_CHAT" experiments null "$ALL_NAMES" null
ensure_key smoke-test "$KEY_SMOKE_TEST" experiments "$BUDGET_KEY_SMOKE_TEST" "$ALL_NAMES" null

printf '%-12s %-12s %-10s %-8s %-6s %s\n' ALIAS TEAM BUDGET_USD RESETS NAMES RPM
for team in permanent experiments; do
  api GET "/team/info?team_id=$team" | jq -r '.team_info | [.team_alias, "-", (.max_budget // "none"), (.budget_duration // "-"), (.models | length), "-"] | @tsv'
done | while IFS=$'\t' read -r a t b d n r; do printf '%-12s %-12s %-10s %-8s %-6s %s\n' "team:$a" "$t" "$b" "$d" "$n" "$r"; done
for key in "$KEY_NODE_RED" "$KEY_CHAT" "$KEY_SMOKE_TEST"; do
  api GET "/key/info?key=$key" | jq -r '.info | [.key_alias, .team_id, (.max_budget // "team"), (.budget_duration // "-"), (.models | length), (.rpm_limit // "-")] | @tsv'
done | while IFS=$'\t' read -r a t b d n r; do printf '%-12s %-12s %-10s %-8s %-6s %s\n' "$a" "$t" "$b" "$d" "$n" "$r"; done
