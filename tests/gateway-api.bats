#!/usr/bin/env bats
# Level 1: the LiteLLM API that scripts/status.sh and scripts/reconcile.sh rely on, called with
# the scripts' own key (KEY_SCRIPTS). A probe written for v1.106.6, kept as a guard against
# LiteLLM upgrades. Findings are in docs/provider-facts.md, "The scripts' routes".
# Raw responses are saved under tests/.artifacts/gateway-api/ (they hold test key values), so a
# later run can refresh tests/fixtures/ by hand, with the key values replaced.

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
  SCRIPTS_KEY="$(test_env KEY_SCRIPTS)"
}

# sk <method> <path> [json]: call the gateway with the scripts' key.
# Sets $output (body) and $SK_STATUS (HTTP status).
sk() {
  local args=(-sS -X "$1" -w '\n%{http_code}' -H "Authorization: Bearer $SCRIPTS_KEY")
  [ -n "${3:-}" ] && args+=(-H 'Content-Type: application/json' -d "$3")
  output="$(curl "${args[@]}" "$GATEWAY_URL$2")"
  SK_STATUS="${output##*$'\n'}"
  output="${output%$'\n'*}"
}

# save <name>: keep the last response, to refresh tests/fixtures/ by hand.
save() {
  printf '%s\n' "$output" > "$SAMPLES/$1.json"
}

# token_hash <key value>: the hash LiteLLM stores and lists for a key (sha256, hex).
token_hash() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# activity <name> <token hash>: today's figures for one name and key from /user/daily/activity.
activity() {
  local day
  day="$(date -u +%F)"
  sk GET "/user/daily/activity?start_date=$day&end_date=$day"
  jq -c --arg n "$1" --arg h "$2" '
    [.results[].breakdown.model_groups[$n].api_key_breakdown[$h] // empty] | first
    | {alias: (.metadata.key_alias // null), requests: (.metrics.successful_requests // 0),
       tokens_in: (.metrics.prompt_tokens // 0), tokens_out: (.metrics.completion_tokens // 0),
       spend: (.metrics.spend // 0)}' <<<"$output"
}

@test "spend per name, key and day is readable" {
  node_red="$(token_hash "$(test_env KEY_NODE_RED)")"
  smoke="$(token_hash "$(test_env KEY_SMOKE_TEST)")"
  # Let spend from earlier tests' calls reach the database first (written every 10 s).
  sleep 12
  before_c="$(activity chat-tasks "$node_red")"
  before_g="$(activity gpt-oss-120b@coreweave "$smoke")"
  gw_call "$(test_env KEY_NODE_RED)" chat-tasks
  [ "$GW_STATUS" = "200" ]
  cost_c="$GW_COST"
  gw_call "$(test_env KEY_SMOKE_TEST)" gpt-oss-120b@coreweave
  [ "$GW_STATUS" = "200" ]
  cost_g="$GW_COST"
  # Daily figures are written in batches; wait for both calls to show.
  deadline=$((SECONDS + 60))
  while :; do
    after_c="$(activity chat-tasks "$node_red")"
    after_g="$(activity gpt-oss-120b@coreweave "$smoke")"
    [ "$(jq -n --argjson b "$before_c" --argjson a "$after_c" '$a.requests > $b.requests')" = "true" ] \
      && [ "$(jq -n --argjson b "$before_g" --argjson a "$after_g" '$a.requests > $b.requests')" = "true" ] && break
    [ "$SECONDS" -lt "$deadline" ] || { echo "daily activity did not change: $after_c $after_g"; false; }
    sleep 2
  done
  sk GET "/user/daily/activity?start_date=$(date -u +%F)&end_date=$(date -u +%F)"
  save daily-activity
  # One call each: 100 tokens in and 50 out (the fake's default), at the cost the gateway reported.
  check='($a.requests - $b.requests) == 1 and ($a.tokens_in - $b.tokens_in) == 100
    and ($a.tokens_out - $b.tokens_out) == 50 and ((($a.spend - $b.spend) - $c) | fabs) < 1e-12'
  echo "chat-tasks: $before_c -> $after_c ($cost_c); gpt: $before_g -> $after_g ($cost_g)"
  [ "$(jq -n --argjson b "$before_c" --argjson a "$after_c" --argjson c "$cost_c" "$check")" = "true" ]
  [ "$(jq -n --argjson b "$before_g" --argjson a "$after_g" --argjson c "$cost_g" "$check")" = "true" ]
  [ "$(jq -r .alias <<<"$after_c")" = "node-red" ]
  [ "$(jq -r .alias <<<"$after_g")" = "smoke-test" ]
}

@test "the scripts' key reads daily activity for every user" {
  # Decides SCRIPTS_ROLE in setup-keys.sh: proxy_admin_viewer if this passes, else proxy_admin.
  smoke="$(token_hash "$(test_env KEY_SMOKE_TEST)")"
  chat="$(token_hash "$(test_env KEY_CHAT)")"
  gw_call "$(test_env KEY_SMOKE_TEST)" chat-tasks
  [ "$GW_STATUS" = "200" ]
  gw_call "$(test_env KEY_CHAT)" chat-tasks
  [ "$GW_STATUS" = "200" ]
  # Daily figures are written in batches; wait for both keys to show.
  deadline=$((SECONDS + 60))
  while :; do
    sk GET "/user/daily/activity?start_date=$(date -u +%F)&end_date=$(date -u +%F)"
    [ "$SK_STATUS" = "200" ] || { echo "status $SK_STATUS: $output"; false; }
    [ "$(jq --arg s "$smoke" --arg c "$chat" \
      '[.results[].breakdown.api_keys | keys[]] | index($s) != null and index($c) != null' <<<"$output")" = "true" ] && break
    [ "$SECONDS" -lt "$deadline" ] || { echo "not both keys: $output"; false; }
    sleep 2
  done
}

@test "team info shows budget and reset time" {
  sk GET '/team/info?team_id=experiments'
  [ "$SK_STATUS" = "200" ]
  save team-info
  [ "$(jq --argjson b "$(home_value BUDGET_TEAM_EXPERIMENTS)" '.team_info | .max_budget == $b and .budget_duration == "30d" and (.budget_reset_at | type) == "string"' <<<"$output")" = "true" ]
}

@test "global budget readable" {
  sk GET /global/spend
  [ "$SK_STATUS" = "200" ]
  global="$(awk '/^  max_budget:/ { print $2 }' "$RAPIDSELECTOR_GATEWAY_CONFIG")"
  [ "$(jq --argjson g "$global" '.max_budget == $g' <<<"$output")" = "true" ]
}

@test "the scripts' key can change nothing and call no model" {
  failures=()
  body='{"model":"chat-tasks","messages":[{"role":"user","content":"hi"}]}'
  for call in \
    "POST /openrouter/v1/chat/completions $body" \
    "POST /v1/chat/completions $body" \
    'POST /model/new {"model_name":"x","litellm_params":{"model":"openrouter/openai/gpt-4o"}}' \
    'POST /key/delete {"key_aliases":["chat"]}' \
    'POST /key/generate {}' \
    'POST /key/update {"key_alias":"chat","max_budget":1000}' \
    'POST /key/block {"key":"x"}' \
    'POST /user/new {"user_id":"x"}' \
    'POST /global/spend/reset {}' \
    'GET /key/list' \
    'GET /model/info' \
    'GET /spend/logs'; do
    read -r method path json <<<"$call"
    sk "$method" "$path" "$json"
    [ "$SK_STATUS" = "401" ] || [ "$SK_STATUS" = "403" ] || failures+=("$method $path -> $SK_STATUS")
  done
  printf '%s\n' "${failures[@]}"
  [ "${#failures[@]}" -eq 0 ]
  [ "$(upstream_requests | jq length)" = "0" ]
  keys="$(curl -sS -H "Authorization: Bearer $(test_env LITELLM_MASTER_KEY)" "$GATEWAY_URL/key/list")"
  [ "$(jq '.keys | length' <<<"$keys")" = "4" ]
}
