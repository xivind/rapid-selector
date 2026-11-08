#!/usr/bin/env bats
# Level 1: the wiring of the operator scripts on inputs too large or odd for the real stack's
# short runs, against the fake upstream alone, which also serves the gateway's read routes
# (GATEWAY_PORT points at it). Real LiteLLM is tested in tests/ops-scripts.bats.

load helpers

setup_file() {
  fakes_up
  ensure_test_env
  # The fake's own management key (no compose.test.yml here). The gateway routes are on the
  # fake too: each run sets GATEWAY_PORT=18000, since helpers.bash exports GATEWAY_PORT and the
  # environment wins over the settings file.
  WIRING_ENV="$BATS_FILE_TMPDIR/env"
  { grep -v '^OPENROUTER_MANAGEMENT_KEY=' "$TEST_ENV_FILE"
    echo "OPENROUTER_MANAGEMENT_KEY=test-management-key"
  } > "$WIRING_ENV"
  export WIRING_ENV
}

teardown_file() {
  fakes_down
}

setup() {
  curl -sS -X POST "$FAKE_UPSTREAM_URL/_gateway" -d '{}' >/dev/null
  openrouter_state '{}'
}

# run_wired <script path> [args...]: through rapidselector.sh, from the repository.
run_wired() {
  local script="$1"
  shift
  run env RAPIDSELECTOR_ENV_FILE="$WIRING_ENV" GATEWAY_PORT=18000 OPENROUTER_API_BASE_URL="$FAKE_UPSTREAM_URL/api/v1" \
    bash -c 'cd "$1" && shift && exec ./rapidselector.sh run-script "$@"' _ "$REPO" "$script" "$@"
  echo "${output:0:2000}"
}

# post_file <path> <file>: POST a file to the fake (too large for a command-line argument).
post_file() {
  curl -sS -X POST "$FAKE_UPSTREAM_URL$1" -H 'Content-Type: application/json' --data-binary "@$2" >/dev/null
}

@test "reconcile.sh reads a month of gateway pages and activity larger than one argument" {
  # 15 pages, one day each, in the saved page's shape (about 175 KB), and OpenRouter's activity
  # for the same days split over 40 endpoint tags (about 300 KB): each far past 128 KiB.
  jq -c '{pages: [range(1; 16) as $d | $f[0] | .results[0].date = ("2026-11-" + ($d | tostring | if length == 1 then "0" + . else . end))]}' \
    --slurpfile f "$REPO/tests/fixtures/gateway-daily-activity.json" -n > "$BATS_TEST_TMPDIR/gateway.json"
  jq -c '{activity: [.pages[].results[0] | .date as $day | .breakdown.models | to_entries[]
    | .key as $m | .value.metrics.spend as $s | range(40) as $i
    | {date: $day, model: ($m | sub("^openrouter/"; "")), provider_name: "deepinfra/fp\($i)", usage: ($s / 40),
       byok_usage_inference: 0, requests: 1, prompt_tokens: 100, completion_tokens: 50, reasoning_tokens: 0}]}' \
    "$BATS_TEST_TMPDIR/gateway.json" > "$BATS_TEST_TMPDIR/activity.json"
  [ "$(wc -c < "$BATS_TEST_TMPDIR/gateway.json")" -gt 131072 ]
  [ "$(wc -c < "$BATS_TEST_TMPDIR/activity.json")" -gt 131072 ]
  post_file /_gateway "$BATS_TEST_TMPDIR/gateway.json"
  post_file /_openrouter "$BATS_TEST_TMPDIR/activity.json"
  RECONCILE_TODAY=2026-11-30 run_wired scripts/reconcile.sh --days 29
  [ "$status" -eq 0 ]
  [ "$(grep -c ' total ' <<<"$output")" = "15" ]
  [[ "$output" == *"Nothing flagged."* ]]
}

@test "write-metrics.sh run from another directory writes both files" {
  dir="$BATS_TEST_TMPDIR/textfile"
  mkdir -p "$dir"
  # As cron runs it: from the home directory, by its full path.
  cd "$BATS_TEST_TMPDIR"
  run env RAPIDSELECTOR_ENV_FILE="$WIRING_ENV" GATEWAY_PORT=18000 OPENROUTER_API_BASE_URL="$FAKE_UPSTREAM_URL/api/v1" \
    "$REPO/scripts/write-metrics.sh" "$dir"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -s "$dir/rapidselector_status.prom" ]
  [ -s "$dir/rapidselector_reconcile.prom" ]
}
