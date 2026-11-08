#!/usr/bin/env bats
# Level 1: scripts/status.sh and scripts/reconcile.sh through ./rapidselector.sh run-script,
# against the real gateway and the fake upstream's OpenRouter management API. Their logic is
# tested without Docker in tests/ops-logic.bats.

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
  upstream_mode 200
  openrouter_state '{}'
}

# run_ops <script> [args...]: run scripts/<script> through rapidselector.sh with the test
# settings and the fake OpenRouter; sets $status and $output (stdout and stderr).
run_ops() {
  local script="$1"
  shift
  run env RAPIDSELECTOR_ENV_FILE="$TEST_ENV_FILE" OPENROUTER_API_BASE_URL="$FAKE_UPSTREAM_URL/api/v1" \
    bash -c 'cd "$1" && shift && exec ./rapidselector.sh run-script "$@"' _ "$REPO" "scripts/$script" "$@"
  echo "$output"
}

# no_secret_in_output: none of the keys the scripts hold appears in $output.
no_secret_in_output() {
  local name
  for name in KEY_SCRIPTS OPENROUTER_MANAGEMENT_KEY LITELLM_MASTER_KEY; do
    [[ "$output" != *"$(test_env "$name")"* ]] || { echo "$name in the output"; return 1; }
  done
}

STATUS_GAUGES="rapidselector_openrouter_balance_usd rapidselector_openrouter_key_limit_usd
  rapidselector_openrouter_key_remaining_usd rapidselector_openrouter_key_usage_month_usd
  rapidselector_openrouter_key_disabled rapidselector_status_warnings
  rapidselector_status_last_run_timestamp_seconds"

@test "status.sh shows the fake's balance and exits 0" {
  openrouter_state '{"credits":{"total_credits":20,"total_usage":1}}'
  run_ops status.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *'$19.00'* ]]
  # It read the inference key by its hash, found in the list by name, with disabled keys listed.
  [ "$(openrouter_requests | jq '[.[] | select(.path | test("^/api/v1/keys/.+"))] | length')" = "1" ]
}

@test "status.sh exits 1 with a balance below \$10" {
  openrouter_state '{"credits":{"total_credits":20,"total_usage":15}}'
  run_ops status.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"below \$10"* ]]
}

@test "status.sh exits 2 when OpenRouter's credits fail" {
  openrouter_state '{"fail":"credits"}'
  run_ops status.sh
  [ "$status" -eq 2 ]
  [[ "$output" == *"credits"* ]]
}

@test "status.sh exits 2 with a rejected management key" {
  OPENROUTER_MANAGEMENT_KEY=wrong run_ops status.sh
  [ "$status" -eq 2 ]
  [[ "$output" == *"management key rejected (expired?)"* ]]
  [[ "$output" != *'$0.00'* ]]
}

@test "status.sh --prometheus prints every gauge" {
  run_ops status.sh --prometheus
  [ "$status" -eq 0 ]
  for gauge in $STATUS_GAUGES; do
    [ "$(grep -c "^$gauge " <<<"$output")" = "1" ] || { echo "not once: $gauge"; false; }
    grep -q "^# TYPE $gauge gauge$" <<<"$output"
    grep -q "^# HELP $gauge " <<<"$output"
  done
  # No expiry is set in the test settings, so the days left are left out.
  ! grep -q "^rapidselector_management_key_days_left" <<<"$output"
  # Every sample line is a name and a number.
  [ "$(grep -v '^#' <<<"$output" | grep -cvE '^rapidselector_[a-z_]+ -?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$')" = "0" ]
}

@test "status.sh prints no secret" {
  run_ops status.sh
  no_secret_in_output
  OPENROUTER_MANAGEMENT_KEY=wrong run_ops status.sh
  no_secret_in_output
}
