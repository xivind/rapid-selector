#!/usr/bin/env bats
# Level 1: scripts/drain-balance.sh (tests A and B) against the fake upstream.
# Fake answers report 100 prompt and 1000 completion tokens, so one call to
# qwen3.8-2.4t-a95b@siliconflow costs 100 x $2/M + 1000 x $6/M = $0.0062.

bats_require_minimum_version 1.5.0

load helpers

setup_file() {
  stack_up
  run_setup_keys >/dev/null
}

teardown_file() {
  stack_down
}

setup() {
  upstream_reset
  fake_tokens 100 1000
}

# drain <stdin text> [args...]: run the script through rapidselector.sh.
drain() {
  local input="$1"
  shift
  (cd "$REPO" && printf '%s\n' "$input" | RAPIDSELECTOR_ENV_FILE="$TEST_ENV_FILE" \
    ./rapidselector.sh run-script scripts/drain-balance.sh "$@")
}

# fake_mode <json>: set the fake upstream's mode, with this file's token counts.
fake_mode() {
  curl -sS -X POST "$FAKE_UPSTREAM_URL/_mode" \
    -d "$(jq -nc --argjson m "$1" '{status:200, prompt_tokens:100, completion_tokens:1000} + $m')" >/dev/null
}

# sizes: the max_tokens of every call the upstream received, in order.
sizes() {
  upstream_requests | jq -c '[.[].body.max_tokens]'
}

calls_received() {
  upstream_requests | jq length
}

drain_keys_left() {
  curl -sS -G -H "Authorization: Bearer $(test_env LITELLM_MASTER_KEY)" \
    --data-urlencode "key_alias=drain-test" "$GATEWAY_URL/key/list" | jq '.keys | length'
}

@test "refuses to start without typed confirmation" {
  run drain "yes" --max-usd 1
  [ "$status" -eq 1 ]
  [ "$(upstream_requests | jq length)" = "0" ]
  [ "$(drain_keys_left)" = "0" ]
}

@test "the default size is 8192 on the largest model" {
  run drain "drain" --max-usd 1 --max-calls 1
  [ "$status" -eq 0 ]
  [ "$(upstream_requests | jq -c '.[0].body | {model, max_tokens}')" = '{"model":"qwen/qwen3.8-2.4t-a95b","max_tokens":8192}' ]
}

@test "the summary shows the spend the gateway recorded" {
  run drain "drain" --max-usd 1 --max-calls 1
  echo "$output"
  grep -qx "recorded_spend_usd 0.0062.*" <<<"$output"
}

@test "--max-tokens sets the size" {
  run drain "drain" --max-usd 1 --max-calls 1 --max-tokens 512
  [ "$status" -eq 0 ]
  [ "$(sizes)" = "[512]" ]
}

@test "--parallel sends the calls of a round at once, and rounds in turn" {
  fake_mode '{"delay_ms":2000}'
  run drain "drain" --max-usd 1 --max-calls 3 --parallel 2
  echo "$output"
  grep -qx "calls_succeeded 3" <<<"$output"
  # The first two arrive together; the third only after they are answered.
  [ "$(upstream_requests | jq '.[1].at - .[0].at < 1.5')" = "true" ]
  [ "$(upstream_requests | jq '.[2].at - .[0].at >= 2')" = "true" ]
}

@test "the default is 5 calls at once" {
  fake_mode '{"delay_ms":2000}'
  run drain "drain" --max-usd 1 --max-calls 5
  echo "$output"
  grep -qx "calls_succeeded 5" <<<"$output"
  [ "$(upstream_requests | jq '.[4].at - .[0].at < 1.5')" = "true" ]
}

@test "--max-calls shrinks the last round" {
  run drain "drain" --max-usd 1 --max-calls 3 --parallel 5
  [ "$status" -eq 0 ]
  grep -qx "calls_succeeded 3" <<<"$output"
  grep -q "stopped: max-calls" <<<"$output"
  [ "$(calls_received)" = "3" ]
}

@test "--max-calls counts refused calls" {
  fake_mode '{"status":402,"refusal":"in_flight"}'
  DRAIN_RETRY_WAIT=0 run drain "drain" --max-usd 1 --max-calls 3 --parallel 1
  echo "$output"
  grep -qx "calls_succeeded 0" <<<"$output"
  grep -q "stopped: max-calls" <<<"$output"
  [ "$(calls_received)" = "3" ]
}

@test "a round that could pass --max-usd does not start" {
  # 0.0062 a call. Worst case per call: (1000 + 100) x $6/M = 0.0066.
  run drain "drain" --max-usd 0.02 --max-tokens 1000 --parallel 1
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "stopped: max-usd" <<<"$output"
  grep -qx "calls_succeeded 3" <<<"$output"
  [ "$(calls_received)" = "3" ]
}

@test "no call is sent when one round could already pass --max-usd" {
  run drain "drain" --max-usd 0.001
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "stopped: max-usd" <<<"$output"
  [ "$(calls_received)" = "0" ]
  [ "$(drain_keys_left)" = "0" ]
}

@test "a limit refusal halves the size, and calls go on" {
  fake_mode '{"refuse_above_tokens":256}'
  run drain "drain" --max-usd 1 --max-tokens 1024 --max-calls 6 --parallel 1
  echo "$output"
  [ "$(sizes)" = "[1024,512,256,256,256,256]" ]
  grep -qx "calls_succeeded 4" <<<"$output"
}

@test "a plain 402 ends in refused below the smallest size" {
  fake_mode '{"status":402}'
  run drain "drain" --max-usd 1 --max-tokens 64 --parallel 1
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(sizes)" = "[64,32,16]" ]
  grep -q "stopped: refused" <<<"$output"
  grep -qx "calls_succeeded 0" <<<"$output"
  [ "$(drain_keys_left)" = "0" ]
}

@test "weight_exceeds_budget is a limit refusal, and its reason is shown" {
  fake_mode '{"status":402,"refusal":"weight"}'
  run drain "drain" --max-usd 1 --max-tokens 64 --parallel 1
  echo "$output"
  [ "$(sizes)" = "[64,32,16]" ]
  grep -q "stopped: refused" <<<"$output"
  grep -q "weight_exceeds_budget" <<<"$output"
}

@test "a key limit as 402 is a limit refusal" {
  fake_mode '{"status":402,"refusal":"key_limit_402"}'
  run drain "drain" --max-usd 1 --max-tokens 64 --parallel 1
  echo "$output"
  [ "$(sizes)" = "[64,32,16]" ]
  grep -q "stopped: refused" <<<"$output"
  grep -q "openrouter_key_limit" <<<"$output"
}

@test "a key limit as 403 is a limit refusal" {
  fake_mode '{"status":402,"refusal":"key_limit_403"}'
  run drain "drain" --max-usd 1 --max-tokens 64 --parallel 1
  echo "$output"
  grep -q "stopped: refused" <<<"$output"
  # The gateway sends a 403 upstream more than once, so only the smallest size is asserted.
  [ "$(upstream_requests | jq '[.[].body.max_tokens] | min')" = "16" ]
}

@test "a round with answers and refusals counts the answers and halves the size" {
  fake_mode '{"fail_after":2}'
  run drain "drain" --max-usd 1 --max-tokens 32 --parallel 5
  echo "$output"
  grep -qx "calls_succeeded 2" <<<"$output"
  [ "$(upstream_requests | jq -c '[.[].body.max_tokens] | unique')" = "[16,32]" ]
  grep -q "stopped: refused" <<<"$output"
}

@test "an in-flight refusal waits and keeps the size" {
  fake_mode '{"refuse_first":2,"refusal":"in_flight"}'
  DRAIN_RETRY_WAIT=0 run drain "drain" --max-usd 1 --max-calls 3 --parallel 1
  echo "$output"
  [ "$(sizes)" = "[8192,8192,8192]" ]
  grep -qx "calls_succeeded 1" <<<"$output"
}

@test "in-flight refusals give up after 6 rounds with no answer" {
  fake_mode '{"status":402,"refusal":"in_flight"}'
  DRAIN_RETRY_WAIT=0 run drain "drain" --max-usd 1 --parallel 1
  echo "$output"
  [ "$(calls_received)" = "6" ]
  grep -q "stopped: in-flight" <<<"$output"
}

@test "a fault stops the test and is not reported as a refusal" {
  fake_mode '{"status":503}'
  run drain "drain" --max-usd 1 --parallel 1
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "stopped: error" <<<"$output"
  grep -qx "calls_succeeded 0" <<<"$output"
  [ "$(upstream_requests | jq -c '[.[].body.max_tokens] | unique')" = "[8192]" ]
}

@test "a connection failure is a fault" {
  fake_mode '{"delay_ms":3000}'
  DRAIN_CURL_TIMEOUT=1 run drain "drain" --max-usd 1 --max-calls 3 --parallel 1
  echo "$output"
  grep -q "stopped: error" <<<"$output"
  grep -qx "calls_succeeded 0" <<<"$output"
  grep -q "round 1: max_tokens 8192: 000," <<<"$output"
}

@test "a connection failure after a refusal is still a fault" {
  # The first call is refused at once; the next one outlives the time limit.
  fake_mode '{"refuse_first":1,"refusal":"key_limit_402","delay_ms":3000}'
  DRAIN_CURL_TIMEOUT=1 run drain "drain" --max-usd 1 --max-tokens 64 --parallel 1
  echo "$output"
  grep -q "stopped: error" <<<"$output"
  grep -q "round 2: max_tokens 32: 000," <<<"$output"
}

@test "an answer with no cost is a fault, so spend cannot go uncounted" {
  fake_mode '{"cost":0}'
  run drain "drain" --max-usd 1 --max-calls 3 --parallel 1
  echo "$output"
  grep -q "stopped: error" <<<"$output"
  [ "$(calls_received)" = "1" ]
}

@test "the cost of the calls adds up over a mixed round" {
  fake_mode '{"fail_after":2}'
  run drain "drain" --max-usd 1 --max-tokens 32 --parallel 5
  echo "$output"
  grep -qx "cost_of_calls_usd 0.012400" <<<"$output"
}

@test "the summary waits for all the spend to be recorded" {
  # Spend is written every 10 seconds, so these calls span at least one write.
  fake_mode '{"delay_ms":6000}'
  run drain "drain" --max-usd 1 --max-calls 3 --parallel 1
  echo "$output"
  recorded="$(grep '^recorded_spend_usd' <<<"$output" | cut -d' ' -f2)"
  awk -v r="$recorded" 'BEGIN { exit !(r > 0.0186 * 0.99) }'
}

@test "bad numbers are refused before anything is created" {
  for args in "--parallel 0" "--max-tokens 0" "--parallel x" "--max-tokens 1.5"; do
    # shellcheck disable=SC2086  # the flag and its value are meant to split
    run drain "drain" --max-usd 1 $args
    [ "$status" -eq 2 ] || { echo "$args gave status $status"; false; }
  done
  [ "$(calls_received)" = "0" ]
  [ "$(drain_keys_left)" = "0" ]
}

@test "TERM during a round stops the calls and deletes the temporary key" {
  fake_mode '{"delay_ms":20000}'
  (cd "$REPO" && printf 'drain\n' | RAPIDSELECTOR_ENV_FILE="$TEST_ENV_FILE" \
    ./rapidselector.sh run-script scripts/drain-balance.sh --max-usd 1 > "$BATS_TEST_TMPDIR/out" 2>&1) &
  pid=$!
  for _ in $(seq 1 30); do [ "$(calls_received)" = "5" ] && break; sleep 1; done
  [ "$(calls_received)" = "5" ]
  pkill -TERM -f "drain-balance.sh --max-usd 1" || true
  wait "$pid" || true
  for _ in $(seq 1 10); do [ "$(drain_keys_left)" = "0" ] && break; sleep 1; done
  cat "$BATS_TEST_TMPDIR/out"
  [ "$(drain_keys_left)" = "0" ]
  run ! pgrep -f '^curl -sS .*chat/completions'
}

# Last in the file: the team's budget stays used up, apart from what run_setup_keys restores.
@test "the gateway's own budget is told apart from OpenRouter's limit" {
  gw_call "$(test_env KEY_SMOKE_TEST)" "qwen3.8-2.4t-a95b@siliconflow"
  wait_for_key_spend_above "$(test_env KEY_SMOKE_TEST)" 0.006
  run_setup_keys BUDGET_TEAM_EXPERIMENTS=0.005 >/dev/null
  run drain "drain" --max-usd 0.004 --max-tokens 16 --parallel 1
  run_setup_keys >/dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "stopped: gateway-budget" <<<"$output"
}
