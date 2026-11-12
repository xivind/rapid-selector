#!/usr/bin/env bats
# Level 1: scripts/smoke-test.sh against the fake upstream.

load helpers

setup_file() {
  stack_up
  run_setup_keys >/dev/null
}

teardown_file() {
  stack_down
}

setup() {
  upstream_mode 200
}

@test "passes against a healthy stack and reports both refusals" {
  run run_smoke_test
  echo "$output"
  [ "$status" -eq 0 ]
  for role in $(config_roles); do
    grep -qE "^$role +200 +0\.[0-9]*[1-9]" <<<"$output" || { echo "no line for $role"; false; }
  done
  grep -q "refused: openai/gpt-4o" <<<"$output"
  grep -q "refused: /openrouter/v1/chat/completions" <<<"$output"
  grep -qE "^total_usd [0-9.]+" <<<"$output"
}

@test "--all covers every name" {
  run run_smoke_test --all
  [ "$status" -eq 0 ]
  [ "$(grep -cE '^[^ ]+ +200 ' <<<"$output")" = "$(config_count)" ]
}

@test "reasoning entries get low effort and a small max_tokens" {
  upstream_reset
  run run_smoke_test --all
  [ "$status" -eq 0 ]
  [ "$(upstream_requests | jq '[.[].body | select(.model == "openai/gpt-oss-120b")][0] | .reasoning_effort == "low" and .max_tokens == 256')" = "true" ]
  [ "$(upstream_requests | jq '[.[].body | select(.model == "meta-llama/llama-3.1-8b-instruct")][0] | has("reasoning_effort") | not')" = "true" ]
}

@test "fails when a call returns 500" {
  upstream_mode 500
  run run_smoke_test
  [ "$status" -eq 1 ]
  grep -qi "failed" <<<"$output"
}
