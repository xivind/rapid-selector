#!/usr/bin/env bash
# OpenRouter's balance, the inference key's limit and usage, the gateway's global and team
# spend against budget, and the management key's expiry, on one screen: no upstream tool
# shows both sides at once. Run it weekly, before a top-up, and when a Grafana
# alert or a slow model makes you wonder.
# Run:     ./rapidselector.sh run-script scripts/status.sh [--prometheus]
#          --prometheus prints Prometheus text format instead, for node_exporter's textfile
#          collector (README, "Optional: cost figures in Prometheus").
# Secrets: OPENROUTER_MANAGEMENT_KEY (read-only use: credits and keys), KEY_SCRIPTS.
#          OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT and OPENROUTER_INFERENCE_KEY_NAME from .env.
# Cost:    nothing (no model call).
# Exit:    0 all well, 1 a warning (the output says what), 2 a source could not be read or
#          wrong usage, 3 a missing value.
# Warnings: balance below $10, the inference key disabled, a budget above 80% spent, OpenRouter's
# key limit and the gateway's budgets not resetting on the same day, the management key expiring
# within 30 days. The thresholds are at the top of scripts/jq/status.jq.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/scripts/lib.sh"

USAGE="usage: status.sh [--prometheus]"
TEAMS=(permanent experiments)

format=text
case "${1:-}" in
  "") ;;
  --prometheus) format=prometheus ;;
  *) die 2 "$USAGE" ;;
esac
[ "$#" -le 1 ] || die 2 "$USAGE"
require_env KEY_SCRIPTS OPENROUTER_MANAGEMENT_KEY RAPIDSELECTOR_LAN_ADDRESS GATEWAY_PORT

credits="$(or_read /credits)" || die 2 "cannot read OpenRouter's credits"
keys="$(or_read '/keys?include_disabled=true')" || die 2 "cannot read OpenRouter's key list"
key_name="${OPENROUTER_INFERENCE_KEY_NAME:-rapidselector-gateway}"
hash="$(inference_key_hash "$keys")" || die 2 "no key named $key_name in OpenRouter's key list"
key="$(or_read "/keys/$hash")" || die 2 "cannot read OpenRouter's key $key_name"
global="$(gw_read /global/spend)" || die 2 "cannot read the gateway's global spend"
teams="[]"
for team in "${TEAMS[@]}"; do
  info="$(gw_read "/team/info?team_id=$team")" || die 2 "cannot read the gateway's team $team"
  teams="$(jq -c --argjson t "$info" '. + [$t]' <<<"$teams")" || die 2 "unexpected answer for team $team"
done

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
report="$(jq -n --arg now "$now" --arg expires "${OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT:-}" --arg key_name "$key_name" \
  --argjson credits "$credits" --argjson key "$key" --argjson global "$global" --argjson teams "$teams" \
  -f "$ROOT/scripts/jq/status.jq")" || die 2 "unexpected answer from OpenRouter or the gateway (see above)"

if [ "$format" = prometheus ]; then
  jq -r --arg now "$now" '
    [ ["openrouter_balance_usd", "OpenRouter balance (credits minus usage), USD.", .balance_usd],
      ["openrouter_key_limit_usd", "Credit limit of the inference key, USD.", .key.limit_usd],
      ["openrouter_key_remaining_usd", "What is left of the inference key'"'"'s limit, USD.", .key.remaining_usd],
      ["openrouter_key_usage_month_usd", "Inference key usage this month (UTC), USD.", .key.usage_month_usd],
      ["openrouter_key_disabled", "1 if the inference key is disabled.", (if .key.disabled then 1 else 0 end)],
      ["management_key_days_left", "Days until the management key expires.", .management_key_days_left],
      ["status_warnings", "Number of warnings status.sh printed.", (.warnings | length)],
      ["status_last_run_timestamp_seconds", "When status.sh last ran, Unix time.", ($now | fromdateiso8601)] ]
    | .[] | select(.[2] != null)
    | "# HELP rapidselector_\(.[0]) \(.[1])\n# TYPE rapidselector_\(.[0]) gauge\nrapidselector_\(.[0]) \(.[2])"
  ' <<<"$report" || die 2 "could not print the report"
else
  jq -r -L "$ROOT/scripts/jq" --arg now "$now" --arg expires "${OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT:-}" 'include "common";
    def row(name; text): "  \(name + "                    " | .[0:19]) \(text)";
    "rapid-selector status, \($now[0:10]) \($now[11:16]) UTC", "",
    "OpenRouter",
    row("Balance"; .balance_usd | money),
    row("Inference key"; "\(.key.name): limit \(.key.limit_usd // "none" | if type == "number" then money else . end), \(.key.remaining_usd | money) left, resets \(.key.limit_reset // "never")\(if .key.disabled then ", DISABLED" else "" end)"),
    row("Key usage"; "today \(.key.usage_day_usd | money), this week \(.key.usage_week_usd | money), this month \(.key.usage_month_usd | money)"),
    row("Month forecast"; "\(.forecast_month_usd | money) at this month'"'"'s pace"),
    "Gateway (LiteLLM)",
    row("Global budget"; "\(.gateway.spend_usd | money) of \(.gateway.budget_usd | money) spent"),
    (.teams[] | row("Team \(.id)"; "\(.spend_usd | money) of \(.budget_usd | money) spent, resets \(.reset_at // "never" | .[0:10])")),
    "Management key",
    row("Expires"; if .management_key_days_left == null then "not set (OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT in .env)"
                   else "\($expires[0:10]), in \(.management_key_days_left) days" end),
    "",
    (if (.warnings | length) == 0 then "No warnings." else "Warnings:", (.warnings[] | "  ! \(.)") end)
  ' <<<"$report" || die 2 "could not print the report"
fi

[ "$(jq '.warnings | length' <<<"$report")" -eq 0 ] || exit 1
