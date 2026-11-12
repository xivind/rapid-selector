#!/usr/bin/env bats
# Level 1: key and team budgets block, and recorded spend survives a gateway restart.
# Every fake answer reports 100 prompt and 500000 completion tokens, so one chat-tasks call
# costs 100 x $0.02/M + 500000 x $0.04/M, about $0.02, at the example config's price.

load helpers

FINDINGS="$ARTIFACTS/findings.txt"

setup_file() {
  stack_up
  run_setup_keys BUDGET_KEY_SMOKE_TEST=0.03 BUDGET_TEAM_PERMANENT=0.03 >/dev/null
}

teardown_file() {
  stack_down
}

setup() {
  fake_tokens 100 500000
}

# call_until_refused <key> <model> <max_calls>: sets CALLS (successful calls before the refusal),
# REFUSED_STATUS and REFUSED_BODY. Waits after each call so batched spend reaches the database.
call_until_refused() {
  CALLS=0
  REFUSED_STATUS=""
  local i
  for ((i = 1; i <= $3; i++)); do
    gw_call "$1" "$2"
    if [ "$GW_STATUS" != "200" ]; then
      REFUSED_STATUS="$GW_STATUS"
      REFUSED_BODY="$output"
      return 0
    fi
    CALLS=$((CALLS + 1))
    sleep 12
  done
}

@test "key budget blocks" {
  call_until_refused "$(test_env KEY_SMOKE_TEST)" chat-tasks 6
  spend="$(key_info "$(test_env KEY_SMOKE_TEST)" | jq -r '.info.spend')"
  echo "$(date -u +%FT%TZ) budgets.bats: key budget 0.03: $CALLS calls succeeded, then HTTP $REFUSED_STATUS; recorded spend $spend; body $REFUSED_BODY" >> "$FINDINGS"
  [ -n "$REFUSED_STATUS" ]
  [ "$CALLS" -le 4 ]
}

@test "team budget blocks" {
  call_until_refused "$(test_env KEY_NODE_RED)" chat-tasks 6
  spend="$(team_info permanent | jq -r '.team_info.spend')"
  echo "$(date -u +%FT%TZ) budgets.bats: team budget 0.03: $CALLS calls succeeded, then HTTP $REFUSED_STATUS; team spend $spend; body $REFUSED_BODY" >> "$FINDINGS"
  [ -n "$REFUSED_STATUS" ]
  [ "$CALLS" -le 4 ]
}

@test "spend survives a gateway restart" {
  gw_call "$(test_env KEY_SMOKE_TEST)" chat-tasks
  [ "$GW_STATUS" != "200" ]
  sleep 15
  (cd "$REPO" && RAPIDSELECTOR_ENV_FILE="$TEST_ENV_FILE" ./rapidselector.sh \
    -f docker-compose.yml -f tests/compose.fakes.yml -f tests/compose.test.yml restart gateway >/dev/null 2>&1)
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' rapidselector-gateway)" = "healthy" ] && break
    sleep 3
  done
  gw_call "$(test_env KEY_SMOKE_TEST)" chat-tasks
  [ "$GW_STATUS" != "200" ] || { echo "a spent key was accepted after restart"; false; }
}
