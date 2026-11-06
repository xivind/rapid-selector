#!/usr/bin/env bats
# Level 1: the LiteLLM API that tower relies on, called with tower's own key.
# A probe written for v1.106.6 (Task 2 of the tower part 1a plan), kept as a guard
# against LiteLLM upgrades. Findings are in docs/provider-facts.md, "Tower's routes".
# Raw responses are saved under tests/.artifacts/gateway-api/ (they hold test key values).

load helpers

SAMPLES="$ARTIFACTS/gateway-api"

setup_file() {
  stack_up
  run_setup_keys >/dev/null
  mkdir -p "$SAMPLES"
}

teardown_file() {
  stack_down
}

setup() {
  upstream_reset
  upstream_mode 200
  TOWER_KEY="$(test_env TOWER_GATEWAY_KEY)"
}

# tw <method> <path> [json]: call the gateway with tower's key.
# Sets $output (body) and $TW_STATUS (HTTP status).
tw() {
  local args=(-sS -X "$1" -w '\n%{http_code}' -H "Authorization: Bearer $TOWER_KEY")
  [ -n "${3:-}" ] && args+=(-H 'Content-Type: application/json' -d "$3")
  output="$(curl "${args[@]}" "$GATEWAY_URL$2")"
  TW_STATUS="${output##*$'\n'}"
  output="${output%$'\n'*}"
}

# save <name>: keep the last response for tower's unit test samples.
save() {
  printf '%s\n' "$output" > "$SAMPLES/$1.json"
}

# token_hash <key value>: the hash LiteLLM stores and lists for a key (sha256, hex).
token_hash() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

blocked_flag() {
  tw GET '/key/list?return_full_object=true'
  jq -r --arg a "$1" '.keys[] | select(.key_alias == $a) | .blocked' <<<"$output"
}

# activity <name> <token hash>: today's figures for one name and key from /user/daily/activity.
activity() {
  local day
  day="$(date -u +%F)"
  tw GET "/user/daily/activity?start_date=$day&end_date=$day"
  jq -c --arg n "$1" --arg h "$2" '
    [.results[].breakdown.model_groups[$n].api_key_breakdown[$h] // empty] | first
    | {alias: (.metadata.key_alias // null), requests: (.metrics.successful_requests // 0),
       tokens_in: (.metrics.prompt_tokens // 0), tokens_out: (.metrics.completion_tokens // 0),
       spend: (.metrics.spend // 0)}' <<<"$output"
}

@test "model info shows pin, prices, max_tokens and kind" {
  tw GET /model/info
  [ "$TW_STATUS" = "200" ]
  save gateway-model-info
  entry="$(jq -c '.data[] | select(.model_name == "classify")' <<<"$output")"
  [ "$(jq -c '.litellm_params.extra_body.provider.order' <<<"$entry")" = '["deepinfra/fp8"]' ]
  [ "$(jq '.model_info.input_cost_per_token > 0' <<<"$entry")" = "true" ]
  [ "$(jq '.litellm_params.max_tokens' <<<"$entry")" = "1024" ]
  [ "$(jq -r '.model_info.rapidselector_kind' <<<"$entry")" = "role" ]
  [ "$(jq '.data | length' <<<"$output")" = "11" ]
  # No provider key value, under any field name.
  [ "$(jq '[.. | objects | has("api_key")] | any' <<<"$output")" = "false" ]
  [[ "$output" != *"$(test_env RAPIDSELECTOR_OPENROUTER_KEY)"* ]]
}

@test "keys can be listed with their blocked flag" {
  tw GET '/key/list?return_full_object=true'
  [ "$TW_STATUS" = "200" ]
  save gateway-key-list
  [ "$(jq -c '[.keys[].key_alias] | sort' <<<"$output")" = '["chat","node-red","smoke-test","tower"]' ]
  # Every key has a token hash, and a blocked field (null until it has been blocked once).
  [ "$(jq '[.keys[] | (.token | test("^[0-9a-f]{64}$")) and has("blocked")] | all' <<<"$output")" = "true" ]
  [ "$(jq -r '.keys[] | select(.key_alias == "node-red") | .token' <<<"$output")" = "$(token_hash "$(test_env KEY_NODE_RED)")" ]
}

@test "a key can be blocked by hash and unblocked" {
  hash="$(token_hash "$(test_env KEY_NODE_RED)")"
  tw POST /key/block "{\"key\":\"$hash\"}"
  [ "$TW_STATUS" = "200" ]
  [ "$(blocked_flag node-red)" = "true" ]
  gw_call "$(test_env KEY_NODE_RED)" classify
  [ "$GW_STATUS" = "401" ]
  [[ "$output" == *"Key is blocked"* ]]
  [ "$(upstream_requests | jq length)" = "0" ]
  tw POST /key/unblock "{\"key\":\"$hash\"}"
  [ "$TW_STATUS" = "200" ]
  [ "$(blocked_flag node-red)" = "false" ]
  gw_call "$(test_env KEY_NODE_RED)" classify
  [ "$GW_STATUS" = "200" ]
}

@test "spend per name, key and day is readable" {
  node_red="$(token_hash "$(test_env KEY_NODE_RED)")"
  smoke="$(token_hash "$(test_env KEY_SMOKE_TEST)")"
  # Let spend from earlier tests' calls reach the database first (written every 10 s).
  sleep 12
  before_c="$(activity classify "$node_red")"
  before_g="$(activity gpt-oss-120b@deepinfra "$smoke")"
  gw_call "$(test_env KEY_NODE_RED)" classify
  [ "$GW_STATUS" = "200" ]
  cost_c="$GW_COST"
  gw_call "$(test_env KEY_SMOKE_TEST)" gpt-oss-120b@deepinfra
  [ "$GW_STATUS" = "200" ]
  cost_g="$GW_COST"
  # Daily figures are written in batches; wait for both calls to show.
  deadline=$((SECONDS + 60))
  while :; do
    after_c="$(activity classify "$node_red")"
    after_g="$(activity gpt-oss-120b@deepinfra "$smoke")"
    [ "$(jq -n --argjson b "$before_c" --argjson a "$after_c" '$a.requests > $b.requests')" = "true" ] \
      && [ "$(jq -n --argjson b "$before_g" --argjson a "$after_g" '$a.requests > $b.requests')" = "true" ] && break
    [ "$SECONDS" -lt "$deadline" ] || { echo "daily activity did not change: $after_c $after_g"; false; }
    sleep 2
  done
  tw GET "/user/daily/activity?start_date=$(date -u +%F)&end_date=$(date -u +%F)"
  save gateway-daily-activity
  # One call each: 100 tokens in and 50 out (the fake's default), at the cost the gateway reported.
  check='($a.requests - $b.requests) == 1 and ($a.tokens_in - $b.tokens_in) == 100
    and ($a.tokens_out - $b.tokens_out) == 50 and ((($a.spend - $b.spend) - $c) | fabs) < 1e-12'
  echo "classify: $before_c -> $after_c ($cost_c); gpt: $before_g -> $after_g ($cost_g)"
  [ "$(jq -n --argjson b "$before_c" --argjson a "$after_c" --argjson c "$cost_c" "$check")" = "true" ]
  [ "$(jq -n --argjson b "$before_g" --argjson a "$after_g" --argjson c "$cost_g" "$check")" = "true" ]
  [ "$(jq -r .alias <<<"$after_c")" = "node-red" ]
  [ "$(jq -r .alias <<<"$after_g")" = "smoke-test" ]
}

@test "team and key info show budgets and reset times" {
  tw GET '/team/info?team_id=experiments'
  [ "$TW_STATUS" = "200" ]
  save gateway-team-info
  [ "$(jq '.team_info | .max_budget == 24 and .budget_duration == "30d" and (.budget_reset_at | type) == "string"' <<<"$output")" = "true" ]
  hash="$(token_hash "$(test_env KEY_SMOKE_TEST)")"
  tw GET "/key/info?key=$hash"
  [ "$TW_STATUS" = "200" ]
  save gateway-key-info
  [ "$(jq -r .key <<<"$output")" = "$hash" ]
  [ "$(jq '.info | .key_alias == "smoke-test" and .max_budget == 1 and .budget_duration == "30d" and (.budget_reset_at | type) == "string"' <<<"$output")" = "true" ]
  # Without a key parameter, /key/info describes the calling key: tower's own hash.
  tw GET /key/info
  [ "$TW_STATUS" = "200" ]
  [ "$(jq -r .key <<<"$output")" = "$(token_hash "$TOWER_KEY")" ]
}

@test "global budget readable or not" {
  # The global budget, live, and the spend log retention are readable through the API.
  tw GET /global/spend
  [ "$TW_STATUS" = "200" ]
  [ "$(jq '.max_budget' <<<"$output")" = "32" ] || [ "$(jq '.max_budget' <<<"$output")" = "32.0" ]
  tw GET '/config/field/info?field_name=maximum_spend_logs_retention_period'
  [ "$TW_STATUS" = "200" ]
  [ "$(jq -r '.field_value' <<<"$output")" = "90d" ]
  # The global budget's window is not: Setup reads it from gateway/config.yaml.
  tw GET '/config/field/info?field_name=budget_duration'
  [ "$TW_STATUS" = "400" ]
}

@test "tower's key cannot reach the pass-through or change models" {
  failures=()
  body='{"model":"classify","messages":[{"role":"user","content":"hi"}]}'
  for call in \
    "POST /openrouter/v1/chat/completions $body" \
    "POST /v1/chat/completions $body" \
    'POST /model/new {"model_name":"x","litellm_params":{"model":"openrouter/openai/gpt-4o"}}' \
    'POST /key/delete {"key_aliases":["chat"]}' \
    'POST /key/generate {}' \
    'POST /key/update {"key_alias":"chat","max_budget":1000}' \
    'POST /user/new {"user_id":"x"}' \
    'POST /global/spend/reset {}' \
    'GET /spend/logs'; do
    read -r method path json <<<"$call"
    tw "$method" "$path" "$json"
    [ "$TW_STATUS" = "401" ] || [ "$TW_STATUS" = "403" ] || failures+=("$method $path -> $TW_STATUS")
  done
  printf '%s\n' "${failures[@]}"
  [ "${#failures[@]}" -eq 0 ]
  [ "$(upstream_requests | jq length)" = "0" ]
  tw GET '/key/list?return_full_object=true'
  [ "$(jq '.keys | length' <<<"$output")" = "4" ]
}
