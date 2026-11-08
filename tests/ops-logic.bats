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

@test "status: two keys with the inference key's name are refused and named" {
  keys="$(jq -c '.data += [.data[1] | .hash = "hash-copy"]' "$FX/openrouter-keys.json")"
  run inference_key_hash "$keys"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 keys named rapidselector-gateway"* ]]
  run inference_key_hash "$(cat "$FX/openrouter-keys.json")"
  [ "$output" = "hash-gateway" ]
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

# gateway_page <{"YYYY-MM-DD": {"<model id>": spend}}> [has_more]: a /user/daily/activity page
# in the saved page's shape, with one result per day and these models' spend.
gateway_page() {
  jq -c --argjson days "$1" --argjson more "${2:-false}" '
    .results[0] as $r | ($r.breakdown.models | to_entries[0].value) as $m
    | .metadata.has_more = $more
    | .results = [$days | to_entries[] | .key as $day | .value as $models
        | $r | .date = $day
        | .breakdown.models = ($models | with_entries(.value as $s | .key |= "openrouter/" + . | .value = ($m | .metrics.spend = $s)))]
  ' "$FX/gateway-daily-activity.json"
}

# reconcile_report <gateway pages json> [activity data json] [first] [last]: reconcile.jq.
reconcile_report() {
  jq -n --argjson gateway "$1" --argjson activity "${2:-$(jq -c .data "$FX/openrouter-activity.json")}" \
    --arg first "${3:-2026-11-01}" --arg last "${4:-2026-11-07}" -f "$REPO/scripts/jq/reconcile.jq"
}

# line <report> <day> <model>: that line of the report, compact, amounts rounded to 6 decimals.
line() {
  jq -c --arg d "$2" --arg m "$3" '.lines[] | select(.day == $d and .model == $m)
    | (.gateway_usd, .openrouter_usd, .diff_usd) |= (. * 1e6 | round / 1e6)' <<<"$1"
}

C2_GATEWAY='{"2026-11-06": {"openai/gpt-oss-120b": 0.001018, "qwen/qwen3.8-2.4t-a95b": 5.10},
  "2026-11-05": {"openai/gpt-oss-120b": 0.000020, "meta-llama/llama-3.2-1b-instruct": 0.000001}}'

@test "reconcile: two hosts of one model meet the gateway's one line" {
  report="$(reconcile_report "[$(gateway_page "$C2_GATEWAY")]")"
  [ "$(line "$report" 2026-11-06 openai/gpt-oss-120b)" \
    = '{"day":"2026-11-06","model":"openai/gpt-oss-120b","gateway_usd":0.001018,"openrouter_usd":0.001014,"diff_usd":4e-06,"flagged":false}' ]
}

@test "reconcile: a large difference is flagged" {
  activity="$(jq -c '.data | map(if .model == "qwen/qwen3.8-2.4t-a95b" then .usage = 4.80 else . end)' "$FX/openrouter-activity.json")"
  report="$(reconcile_report "[$(gateway_page "$C2_GATEWAY")]" "$activity")"
  [ "$(line "$report" 2026-11-06 qwen/qwen3.8-2.4t-a95b | jq -c '[.diff_usd, .flagged]')" = "[0.3,true]" ]
  [ "$(jq '.flagged' <<<"$report")" = "1" ]
  [ "$(jq '.max_abs_diff_usd * 100 | round' <<<"$report")" = "30" ]
}

@test "reconcile: under the floor is not flagged" {
  report="$(reconcile_report "[$(gateway_page '{"2026-11-04": {"openai/gpt-oss-20b": 0.04}}')]")"
  [ "$(line "$report" 2026-11-04 openai/gpt-oss-20b | jq -c '[.gateway_usd, .openrouter_usd, .flagged]')" = "[0.04,0,false]" ]
}

@test "reconcile: a model on one side only keeps its line" {
  report="$(reconcile_report "[$(gateway_page "$C2_GATEWAY")]")"
  [ "$(line "$report" 2026-11-05 meta-llama/llama-3.2-1b-instruct | jq -c '[.gateway_usd, .openrouter_usd, .flagged]')" = "[1e-06,0,false]" ]
  [ "$(jq '.flagged' <<<"$report")" = "0" ]
}

@test "reconcile: every page is added" {
  page1="$(jq -c '.metadata.has_more = true' "$FX/gateway-daily-activity.json")"
  report="$(reconcile_report "[$page1, $(cat "$FX/gateway-daily-activity-page2.json")]")"
  [ "$(line "$report" 2026-11-06 meta-llama/llama-3.2-1b-instruct | jq '.gateway_usd')" = "1e-06" ]
  [ "$(line "$report" 2026-11-06 mistralai/mistral-small-3.2-24b-instruct | jq '.gateway_usd')" = "3.5e-05" ]
  # The same day and model on two pages is added up.
  report="$(reconcile_report "[$page1, $page1]")"
  [ "$(line "$report" 2026-11-06 mistralai/mistral-small-3.2-24b-instruct | jq '.gateway_usd')" = "7e-05" ]
}

@test "reconcile: rows outside the window are left out" {
  report="$(reconcile_report "[$(gateway_page '{"2026-10-31": {"openai/gpt-oss-120b": 1}}')]")"
  [ "$(jq -c '[.lines[].day] | unique' <<<"$report")" = '["2026-11-05","2026-11-06"]' ]
}

@test "reconcile: day totals add the lines" {
  report="$(reconcile_report "[$(gateway_page "$C2_GATEWAY")]")"
  [ "$(jq -c '[.days[].day]' <<<"$report")" = '["2026-11-06","2026-11-05"]' ]
  [ "$(jq -c '.days[0] | (.gateway_usd, .openrouter_usd) |= (. * 1e6 | round / 1e6) | [.gateway_usd, .openrouter_usd, .flagged]' <<<"$report")" \
    = "[5.101018,5.101014,false]" ]
  # Lines: newest day first, then by model.
  [ "$(jq -c '[.lines[] | "\(.day) \(.model)"]' <<<"$report")" \
    = '["2026-11-06 openai/gpt-oss-120b","2026-11-06 qwen/qwen3.8-2.4t-a95b","2026-11-05 meta-llama/llama-3.2-1b-instruct","2026-11-05 openai/gpt-oss-120b"]' ]
}

@test "test settings gain the secret names added since they were written" {
  TEST_ENV_FILE="$BATS_TEST_TMPDIR/test.env"
  printf '%s\n' "RAPIDSELECTOR_LAN_ADDRESS=127.0.0.1" "KEY_CHAT=sk-test-old" > "$TEST_ENV_FILE"
  ensure_test_env
  grep -qx "KEY_CHAT=sk-test-old" "$TEST_ENV_FILE"
  for name in "${RAPIDSELECTOR_SECRETS[@]}" "${RAPIDSELECTOR_OPTIONAL_SECRETS[@]}"; do
    [ "$(grep -c "^$name=." "$TEST_ENV_FILE")" = "1" ] || { echo "not once: $name"; false; }
  done
}
