#!/usr/bin/env bats
# Level 1: scripts/drain-balance.sh (test A) against the fake upstream.
# Fake answers report 100 prompt and 1000 completion tokens, so one call to
# qwen3.8-2.4t-a95b@siliconflow costs 100 x $2/M + 1000 x $6/M = $0.0062.

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

@test "stops at the first 402 and sends a burst of 5" {
  curl -sS -X POST "$FAKE_UPSTREAM_URL/_mode" -d '{"status":200,"prompt_tokens":100,"completion_tokens":1000,"fail_after":3}' >/dev/null
  run drain "drain" --max-usd 1
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx "calls_succeeded 3" <<<"$output"
  grep -q "stopped: refused" <<<"$output"
  [ "$(grep '^burst' <<<"$output" | wc -w)" = "6" ]
  # 3 successes, the refused call, and the burst of 5 reached the upstream.
  [ "$(upstream_requests | jq '[.[] | select(.body.model == "qwen/qwen3.8-2.4t-a95b")] | length')" = "9" ]
  [ "$(drain_keys_left)" = "0" ]
}

@test "calls use the largest model with max_tokens 8192" {
  run drain "drain" --max-usd 1 --max-calls 1
  [ "$status" -eq 0 ]
  [ "$(upstream_requests | jq -c '.[0].body | {model, max_tokens}')" = '{"model":"qwen/qwen3.8-2.4t-a95b","max_tokens":8192}' ]
}

@test "stops at max-calls" {
  run drain "drain" --max-usd 1 --max-calls 3
  [ "$status" -eq 0 ]
  grep -qx "calls_succeeded 3" <<<"$output"
  grep -q "stopped: max-calls" <<<"$output"
  [ "$(upstream_requests | jq length)" = "3" ]
}

@test "stops at max-usd" {
  run drain "drain" --max-usd 0.02
  [ "$status" -eq 0 ]
  grep -q "stopped: max-usd" <<<"$output"
  # 0.0062 per call: the fourth call brings the total past 0.02.
  grep -qx "calls_succeeded 4" <<<"$output"
}

@test "deletes the temporary key on every exit path" {
  curl -sS -X POST "$FAKE_UPSTREAM_URL/_mode" -d '{"status":200,"prompt_tokens":100,"completion_tokens":1000,"delay_ms":1500}' >/dev/null
  (cd "$REPO" && printf 'drain\n' | RAPIDSELECTOR_ENV_FILE="$TEST_ENV_FILE" \
    ./rapidselector.sh run-script scripts/drain-balance.sh --max-usd 1 > "$BATS_TEST_TMPDIR/out" 2>&1) &
  pid=$!
  for _ in $(seq 1 30); do [ "$(drain_keys_left)" = "1" ] && break; sleep 1; done
  [ "$(drain_keys_left)" = "1" ]
  sleep 2
  pkill -TERM -f "drain-balance.sh --max-usd 1" || true
  wait "$pid" || true
  for _ in $(seq 1 10); do [ "$(drain_keys_left)" = "0" ] && break; sleep 1; done
  cat "$BATS_TEST_TMPDIR/out"
  [ "$(drain_keys_left)" = "0" ]
}
