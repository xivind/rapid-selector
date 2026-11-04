#!/usr/bin/env bats
# Level 1: scripts/smoke-test.sh fails when recorded cost is zero (no prices, no upstream cost).

load helpers

setup_file() {
  stack_up tests/compose.noprice.yml
  run_setup_keys >/dev/null
}

teardown_file() {
  stack_down
}

@test "fails when recorded cost is zero" {
  upstream_mode 200
  run run_smoke_test
  echo "$output"
  [ "$status" -eq 1 ]
  grep -qi "cost" <<<"$output"
}
