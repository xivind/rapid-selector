#!/usr/bin/env bats
# Level 1: the Compose stack (db and gateway) and its safety properties.

load helpers

setup_file() {
  stack_up
}

teardown_file() {
  stack_down
}

compose_config() {
  docker compose --project-directory "$REPO" --env-file "${1:-$TEST_ENV_FILE}" \
    -f "$REPO/docker-compose.yml" config --format json
}

@test "compose refuses to run without a required secret" {
  grep -v '^LITELLM_MASTER_KEY=' "$TEST_ENV_FILE" > "$BATS_TEST_TMPDIR/env"
  run env -u LITELLM_MASTER_KEY docker compose --project-directory "$REPO" --env-file "$BATS_TEST_TMPDIR/env" \
    -f "$REPO/docker-compose.yml" config
  [ "$status" -ne 0 ]
  [[ "$output" == *LITELLM_MASTER_KEY* ]]
}

@test "published ports bind to the LAN address only" {
  config="$(compose_config)"
  [ "$(jq -r '[.services[] | .ports // [] | .[] | .host_ip] | unique | join(",")' <<<"$config")" = "127.0.0.1" ]
  [ "$(jq -r '.services.db.ports // [] | length' <<<"$config")" = "0" ]
  [ "$(jq -r '.services.gateway.ports[0].published' <<<"$config")" = "4000" ]
}

@test "gateway depends on a healthy db" {
  config="$(compose_config)"
  [ "$(jq -r '.services.gateway.depends_on.db.condition' <<<"$config")" = "service_healthy" ]
  [ "$(docker inspect -f '{{.State.Health.Status}}' rapidselector-db)" = "healthy" ]
  [ "$(docker inspect -f '{{.State.Health.Status}}' rapidselector-gateway)" = "healthy" ]
}

@test "classify answers through the fake upstream" {
  upstream_reset
  gw_call "$(test_env LITELLM_MASTER_KEY)" classify
  [ "$GW_STATUS" = "200" ]
  [ "$(jq -r '.choices[0].message.content' <<<"$output")" = "fake reply" ]
  [ "$(upstream_requests | jq 'length')" -ge 1 ]
}

@test "the string OPENROUTER_API_KEY appears nowhere in compose, config or .env.example" {
  run grep -l OPENROUTER_API_KEY "$REPO/docker-compose.yml" "$REPO/gateway/config.yaml" "$REPO/.env.example"
  [ "$status" -eq 1 ]
}

@test "no image uses latest or no tag" {
  config="$(compose_config)"
  while read -r image; do
    [[ "$image" == *:* ]]
    [[ "$image" != *:latest ]]
  done < <(jq -r '.services[] | .image' <<<"$config")
}

@test "tower is published on the LAN address only" {
  config="$(compose_config)"
  [ "$(jq -r '.services.tower.ports | length' <<<"$config")" = "1" ]
  [ "$(jq -r '.services.tower.ports[0].host_ip' <<<"$config")" = "127.0.0.1" ]
  [ "$(jq -r '.services.tower.ports[0].published' <<<"$config")" = "4020" ]
  [ "$(jq -r '.services.tower.ports[0].target' <<<"$config")" = "8000" ]
}

@test "tower mounts config read-only and has no docker socket" {
  config="$(compose_config)"
  [ "$(jq -r '[.services.tower.volumes[] | select(.target | startswith("/config/")) | .read_only] | all' <<<"$config")" = "true" ]
  [ "$(jq -r '[.services.tower.volumes[] | select(.target | startswith("/config/"))] | length' <<<"$config")" = "2" ]
  [ "$(jq -r '[.services.tower.volumes[] | select(.source | test("docker.sock"))] | length' <<<"$config")" = "0" ]
  [ "$(jq -r '.services.tower.depends_on.gateway.condition' <<<"$config")" = "service_started" ]
}
