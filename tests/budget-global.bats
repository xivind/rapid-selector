#!/usr/bin/env bats
# Level 1: LiteLLM's global budget blocks, with the low-budget overlay (max_budget 0.05).

load helpers

FINDINGS="$ARTIFACTS/findings.txt"

setup_file() {
  sed 's/^  max_budget: 32$/  max_budget: 0.05/' "$REPO/gateway/config.yaml" > "$ARTIFACTS/config.lowbudget.yaml"
  grep -q '^  max_budget: 0.05$' "$ARTIFACTS/config.lowbudget.yaml"
  stack_up tests/compose.lowbudget.yml
  run_setup_keys >/dev/null
}

teardown_file() {
  stack_down
}

@test "global budget blocks" {
  fake_tokens 100 100000
  calls=0
  status=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    gw_call "$(test_env KEY_CHAT)" classify
    if [ "$GW_STATUS" != "200" ]; then status="$GW_STATUS"; break; fi
    calls=$((calls + 1))
    sleep 12
  done
  echo "$(date -u +%FT%TZ) budget-global.bats: global budget 0.05: $calls calls succeeded, then HTTP $status; body $output" >> "$FINDINGS"
  [ -n "$status" ]
  # LiteLLM checks the global budget against a separately updated total, so it overshoots
  # by a few calls (5 calls at about $0.02 against $0.05 on 2026-11-03). The team budgets,
  # which add up to the global budget, stop within one call.
  [ "$calls" -le 8 ]
}
