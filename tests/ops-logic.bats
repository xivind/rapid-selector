#!/usr/bin/env bats
# The logic of scripts/status.sh and scripts/reconcile.sh, without Docker: their jq programs in
# scripts/jq/ on the saved responses in tests/fixtures/ (see its README for which shapes were
# seen live). The wiring is tested at level 1, in tests/ops-scripts.bats.

load helpers

FX="$REPO/tests/fixtures"

# teams_fixture [jq filter on the permanent team's response]: /team/info for both teams.
teams_fixture() {
  jq -s --argjson f "null" '[.[0], (.[0] | .team_info |= (.team_id = "permanent" | .team_alias = "permanent"
    | .max_budget = 8 | .spend = 0.5))]' "$FX/gateway-team-info.json" | jq -c "${1:-.}"
}

# status_report [jq arguments]: status.jq on the fixtures at 2026-11-15 12:00 UTC. The arguments
# come first, so they win over the defaults (jq 1.6 keeps the first of two with one name).
status_report() {
  jq -n "$@" --arg now 2026-11-15T12:00:00Z --arg expires 2027-11-07 --arg key_name rapidselector-gateway \
    --argjson credits "$(cat "$FX/openrouter-credits.json")" --argjson key "$(cat "$FX/openrouter-key.json")" \
    --argjson global "$(cat "$FX/gateway-global-spend.json")" --argjson teams "$(teams_fixture)" \
    -f "$REPO/scripts/jq/status.jq"
}

# warning_with <text>: the report on stdin has exactly one warning, and it holds <text>.
warning_with() {
  local report
  report="$(cat)"
  echo "$report"
  [ "$(jq '.warnings | length' <<<"$report")" = "1" ]
  jq -e --arg t "$1" '.warnings[0] | contains($t)' <<<"$report" >/dev/null
}

@test "status: balance is credits minus usage" {
  [ "$(status_report | jq '.balance_usd * 100 | round')" = "3481" ]
}

@test "status: the inference key is found by name" {
  run inference_key_hash "$(cat "$FX/openrouter-keys.json")"
  [ "$status" -eq 0 ]
  [ "$output" = "hash-gateway" ]
  OPENROUTER_INFERENCE_KEY_NAME=other run inference_key_hash "$(cat "$FX/openrouter-keys.json")"
  [ "$output" = "hash-other" ]
  OPENROUTER_INFERENCE_KEY_NAME=missing run inference_key_hash "$(cat "$FX/openrouter-keys.json")"
  [ "$status" -eq 1 ]
  [ "$(status_report | jq -c '.key | [.name, .limit_usd, .remaining_usd, .usage_month_usd, .limit_reset]')" = '["rapidselector-gateway",35,28,7,"monthly"]' ]
}

@test "status: forecast for the month" {
  # 7.00 used in the 14.5 days from 1 November 00:00 to 15 November 12:00, a 30-day month.
  [ "$(status_report | jq '.forecast_month_usd * 100 | round')" = "1448" ]
}

@test "status: no warnings on the fixtures" {
  report="$(status_report)"
  echo "$report"
  [ "$(jq -c '.warnings' <<<"$report")" = "[]" ]
  [ "$(jq -c '[.gateway.spend_usd, .gateway.budget_usd]' <<<"$report")" = "[1.23,32]" ]
  [ "$(jq -c '[.teams[] | .id] | sort' <<<"$report")" = '["experiments","permanent"]' ]
  [ "$(jq -r '.teams[] | select(.id == "experiments") | .reset_at' <<<"$report")" = "2026-12-01T00:00:00Z" ]
}

@test "status: balance below \$10 warns" {
  status_report --argjson credits '{"data":{"total_credits":42.25,"total_usage":32.26}}' \
    | warning_with "speed comparisons are unreliable"
}

@test "status: a disabled key warns" {
  status_report --argjson key "$(jq -c '.data.disabled = true' "$FX/openrouter-key.json")" \
    | warning_with "disabled"
}

@test "status: a team above 80% warns" {
  status_report --argjson teams "$(teams_fixture '.[0].team_info.spend = 19.3')" \
    | warning_with "experiments"
}

@test "status: the global budget above 80% warns" {
  status_report --argjson global '{"spend": 26, "max_budget": 32}' | warning_with "global budget"
}

@test "status: a team resetting on another day warns" {
  status_report --argjson teams "$(teams_fixture '.[0].team_info.budget_reset_at = "2026-12-05T00:00:00Z"')" \
    | warning_with "2026-12-05"
}

@test "status: a key limit that does not reset monthly warns" {
  status_report --argjson key "$(jq -c '.data.limit_reset = "weekly"' "$FX/openrouter-key.json")" \
    | warning_with "weekly"
}

@test "status: management key within 30 days warns" {
  report="$(status_report --arg expires 2026-12-01)"
  [ "$(jq '.management_key_days_left' <<<"$report")" = "15" ]
  warning_with "management key" <<<"$report"
}

@test "status: an expired management key warns" {
  status_report --arg expires 2026-11-01 | warning_with "expired"
}

@test "status: management key expiry unknown gives null and no warning" {
  report="$(status_report --arg expires "")"
  [ "$(jq '.management_key_days_left' <<<"$report")" = "null" ]
  [ "$(jq -c '.warnings' <<<"$report")" = "[]" ]
}

@test "amounts: two decimals, more below one cent, the sign before the dollar" {
  [ "$(jq -nc -L "$REPO/scripts/jq" 'include "common"; [19.3, 0.0012, 0.000001, -0.19, 0, null] | map(money)')" \
    = '["$19.30","$0.0012","$0.000001","-$0.19","$0.00","-"]' ]
}
