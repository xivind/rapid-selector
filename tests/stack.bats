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

@test "chat-tasks answers through the fake upstream" {
  upstream_reset
  gw_call "$(test_env LITELLM_MASTER_KEY)" chat-tasks
  [ "$GW_STATUS" = "200" ]
  [ "$(jq -r '.choices[0].message.content' <<<"$output")" = "fake reply" ]
  [ "$(upstream_requests | jq 'length')" -ge 1 ]
}

@test "the string OPENROUTER_API_KEY appears nowhere in compose, config or .env.example" {
  run grep -l OPENROUTER_API_KEY "$REPO/docker-compose.yml" "$RAPIDSELECTOR_GATEWAY_CONFIG" "$REPO/.env.example"
  [ "$status" -eq 1 ]
}

@test "compose mounts the file the rules check reads" {
  source_of() {
    docker compose --project-directory "$REPO" --env-file "$TEST_ENV_FILE" -f "$REPO/docker-compose.yml" config --format json \
      | jq -r '.services.gateway.volumes[] | select(.target == "/app/config.yaml") | .source'
  }
  [ "$(RAPIDSELECTOR_GATEWAY_CONFIG=/x/y.yaml source_of)" = "/x/y.yaml" ]
  # Empty counts as unset for ${VAR:-default}: the default path.
  [ "$(RAPIDSELECTOR_GATEWAY_CONFIG= source_of)" = "$REPO/config/gateway.yaml" ]
}

@test "no image uses latest or no tag" {
  config="$(compose_config)"
  while read -r image; do
    [[ "$image" == *:* ]]
    [[ "$image" != *:latest ]]
  done < <(jq -r '.services[] | .image' <<<"$config")
}
