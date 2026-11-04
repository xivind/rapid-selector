#!/usr/bin/env bats
# Level 1: scripts/setup-keys.sh, the keys it registers, and rapidselector.sh run-script.

load helpers

setup_file() {
  stack_up
  run_setup_keys > "$ARTIFACTS/setup-keys-first.txt"
}

teardown_file() {
  stack_down
}

setup() {
  upstream_reset
  upstream_mode 200
}

# The fields setup-keys controls, plus spend and reset time, for comparison across runs.
key_state() {
  key_info "$1" | jq -S '.info | {key_alias, team_id, models, max_budget, budget_duration, rpm_limit, tpm_limit, allowed_routes, spend, budget_reset_at}'
}
team_state() {
  team_info "$1" | jq -S '.team_info | {team_alias, models, max_budget, budget_duration, spend, budget_reset_at}'
}
all_state() {
  for k in KEY_CHAT KEY_NODE_RED KEY_SMOKE_TEST; do key_state "$(test_env "$k")"; done
  for t in permanent experiments; do team_state "$t"; done
}

@test "setup-keys registers our own key values" {
  for k in KEY_CHAT KEY_NODE_RED KEY_SMOKE_TEST; do
    gw_call "$(test_env "$k")" classify
    [ "$GW_STATUS" = "200" ] || { echo "$k -> $GW_STATUS $output"; false; }
  done
  [ "$(key_state "$(test_env KEY_NODE_RED)" | jq -r '.team_id')" = "permanent" ]
  [ "$(key_state "$(test_env KEY_NODE_RED)" | jq '.rpm_limit == 30 and .tpm_limit == 100000 and .max_budget == 4')" = "true" ]
  [ "$(key_state "$(test_env KEY_SMOKE_TEST)" | jq '.max_budget == 1 and .budget_duration == "30d"')" = "true" ]
  [ "$(key_state "$(test_env KEY_CHAT)" | jq '.max_budget == null')" = "true" ]
  [ "$(team_state permanent | jq '.max_budget == 8 and .budget_duration == "30d"')" = "true" ]
  [ "$(team_state experiments | jq '.max_budget == 24')" = "true" ]
  [ "$(key_state "$(test_env KEY_CHAT)" | jq -c '.allowed_routes')" = '["/v1/chat/completions","/chat/completions","/v1/models","/models"]' ]
  [ "$(team_state experiments | jq '.models | length')" = "11" ]
}

@test "setup-keys prints a summary without key values" {
  out="$(cat "$ARTIFACTS/setup-keys-first.txt")"
  [[ "$out" == *node-red* && "$out" == *smoke-test* && "$out" == *experiments* ]]
  for k in KEY_CHAT KEY_NODE_RED KEY_SMOKE_TEST LITELLM_MASTER_KEY; do
    [[ "$out" != *"$(test_env "$k")"* ]]
  done
}

@test "second run changes nothing unexpected" {
  # Let spend from earlier calls reach the database first (written every 10 s).
  sleep 12
  before="$(all_state)"
  run_setup_keys >/dev/null
  after="$(all_state)"
  [ "$before" = "$after" ] || { diff <(echo "$before") <(echo "$after"); false; }
}

@test "setup-keys restores values edited outside the script" {
  master="$(test_env LITELLM_MASTER_KEY)"
  curl -sS -X POST "$GATEWAY_URL/key/update" -H "Authorization: Bearer $master" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg k "$(test_env KEY_NODE_RED)" '{key:$k, max_budget:100, models:["classify"], rpm_limit:1000}')" >/dev/null
  [ "$(key_state "$(test_env KEY_NODE_RED)" | jq '.max_budget == 100')" = "true" ]
  run_setup_keys >/dev/null
  state="$(key_state "$(test_env KEY_NODE_RED)")"
  [ "$(jq '.max_budget == 4 and .rpm_limit == 30' <<<"$state")" = "true" ]
  [ "$(jq -c '.models | sort' <<<"$state")" = '["chat","classify","code","summarise"]' ]
}

@test "node-red key may use roles only" {
  gw_call "$(test_env KEY_NODE_RED)" chat
  [ "$GW_STATUS" = "200" ]
  upstream_reset
  gw_call "$(test_env KEY_NODE_RED)" gpt-oss-20b@deepinfra
  [ "$GW_STATUS" -ge 400 ] && [ "$GW_STATUS" -lt 500 ]
  [ "$(upstream_requests | jq length)" = "0" ]
}

@test "virtual keys are refused on pass-through and admin routes" {
  # The body names a model every key may use, so only allowed_routes can refuse it.
  for k in KEY_CHAT KEY_NODE_RED KEY_SMOKE_TEST; do
    for path in /openrouter/v1/chat/completions /anthropic/v1/messages /key/generate; do
      code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$GATEWAY_URL$path" \
        -H "Authorization: Bearer $(test_env "$k")" -H 'Content-Type: application/json' \
        -d '{"model":"classify","messages":[{"role":"user","content":"hi"}]}')"
      [ "$code" = "401" ] || [ "$code" = "403" ] || { echo "$k $path -> $code"; false; }
    done
  done
  [ "$(upstream_requests | jq length)" = "0" ]
}

@test "a request body cannot change the pin, zero data retention or the model list" {
  failures=()
  pin='{"order":["deepinfra/fp8"],"only":["deepinfra/fp8"],"allow_fallbacks":false,"zdr":true,"data_collection":"deny"}'
  for override in \
    '{"provider":{"order":["elsewhere"],"allow_fallbacks":true,"zdr":false}}' \
    '{"extra_body":{"provider":{"order":["elsewhere"],"zdr":false}}}' \
    '{"models":["openai/gpt-4o","anthropic/claude-3.5-sonnet"]}' \
    '{"route":"fallback","transforms":["middle-out"]}'; do
    upstream_reset
    gw_call "$(test_env KEY_CHAT)" classify "$override"
    body="$(upstream_requests | jq -c '.[-1].body')"
    [ "$(jq -cS '.provider' <<<"$body")" = "$(jq -cS . <<<"$pin")" ] || failures+=("$override -> provider $(jq -c .provider <<<"$body")")
    [ "$(jq -c '[has("models"), has("route"), has("transforms"), has("extra_body")]' <<<"$body")" = "[false,false,false,false]" ] \
      || failures+=("$override -> forwarded $(jq -c '{models, route, transforms}' <<<"$body")")
  done
  printf '%s\n' "${failures[@]}"
  [ "${#failures[@]}" -eq 0 ]
}

@test "node-red key is refused for an underlying model string" {
  upstream_reset
  gw_call "$(test_env KEY_NODE_RED)" openrouter/qwen/qwen3.8-2.4t-a95b
  [ "$GW_STATUS" -ge 400 ] && [ "$GW_STATUS" -lt 500 ]
  [ "$(upstream_requests | jq length)" = "0" ]
}

@test "run-script passes secrets to the script and not to docker" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/usr/bin/env bash\necho docker-was-called >> "%s/docker-called"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/docker"
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  printf '#!/usr/bin/env bash\n[ -n "$LITELLM_MASTER_KEY" ] && [ -n "$KEY_NODE_RED" ] && echo "got-secrets $1"\n' > "$BATS_TEST_TMPDIR/probe.sh"
  chmod +x "$BATS_TEST_TMPDIR/probe.sh"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" RAPIDSELECTOR_ENV_FILE="$TEST_ENV_FILE" \
    "$REPO/rapidselector.sh" run-script "$BATS_TEST_TMPDIR/probe.sh" arg1
  [ "$status" -eq 0 ]
  [ "$output" = "got-secrets arg1" ]
  [ ! -e "$BATS_TEST_TMPDIR/docker-called" ]
}
