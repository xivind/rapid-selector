#!/usr/bin/env bats
# Level 1: the database stopping and returning, and the containers' resource settings.

load helpers

FINDINGS="$ARTIFACTS/findings.txt"

setup_file() {
  stack_up
  run_setup_keys BUDGET_KEY_SMOKE_TEST=0.03 >/dev/null
}

teardown_file() {
  stack_down
}

@test "a spent key stays refused while the database is down" {
  fake_tokens 100 100000
  # Spend the smoke-test key's $0.03 (about $0.02 per call) and wait for the spend writer.
  for _ in 1 2 3 4 5; do
    gw_call "$(test_env KEY_SMOKE_TEST)" classify
    [ "$GW_STATUS" = "200" ] || break
    sleep 12
  done
  [ "$GW_STATUS" != "200" ]
  docker stop rapidselector-db >/dev/null
  gw_call "$(test_env KEY_SMOKE_TEST)" classify
  spent_status="$GW_STATUS"
  spent_body="${output:0:300}"
  gw_call "$(test_env KEY_CHAT)" classify
  echo "$(date -u +%FT%TZ) resilience.bats: db stopped: spent key -> HTTP $spent_status ($spent_body); chat key -> HTTP $GW_STATUS (${output:0:200})" >> "$FINDINGS"
  [ "$spent_status" != "200" ] || { echo "fail-open: a spent key was served with the database down"; false; }
}

@test "gateway recovers when the database returns" {
  docker start rapidselector-db >/dev/null
  for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' rapidselector-db)" = "healthy" ] && break
    sleep 2
  done
  fake_tokens 100 50
  for _ in $(seq 1 20); do
    gw_call "$(test_env KEY_CHAT)" classify
    [ "$GW_STATUS" = "200" ] && break
    sleep 3
  done
  echo "$(date -u +%FT%TZ) resilience.bats: after the database returned: chat key -> HTTP $GW_STATUS" >> "$FINDINGS"
  [ "$GW_STATUS" = "200" ]
}

@test "every container has log rotation" {
  for c in rapidselector-db rapidselector-gateway rapidselector-chat; do
    [ "$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-size"}}' "$c")" = "10m" ] || { echo "$c log size"; false; }
    [ "$(docker inspect -f '{{index .HostConfig.LogConfig.Config "max-file"}}' "$c")" = "5" ] || { echo "$c log files"; false; }
  done
}
