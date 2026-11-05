#!/usr/bin/env bats
# Level 1: rapidselector.sh loads settings and secrets, then runs docker compose.

load helpers

setup_file() {
  fakes_up
}

teardown_file() {
  fakes_down
}

setup() {
  # A stub docker first on PATH records its arguments and the secrets it was given.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
{
  echo "ARGS=$*"
  for n in POSTGRES_PASSWORD LITELLM_MASTER_KEY LITELLM_SALT_KEY LITELLM_UI_PASSWORD \
           RAPIDSELECTOR_OPENROUTER_KEY WEBUI_SECRET_KEY KEY_CHAT KEY_NODE_RED KEY_SMOKE_TEST; do
    printf '%s=%s\n' "$n" "${!n}"
  done
} >> "$DOCKER_CALL_LOG"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export DOCKER_CALL_LOG="$BATS_TEST_TMPDIR/docker-call"
  export RAPIDSELECTOR_ENV_FILE="$BATS_TEST_TMPDIR/env"
  curl -sS -X POST "$FAKE_SECRETS_URL/_status" -d '{"status":200}' >/dev/null
}

# write_env <SECRETS_SOURCE> [extra lines...]: an env file with every secret set to "v-<NAME>".
write_env() {
  {
    echo "RAPIDSELECTOR_LAN_ADDRESS=127.0.0.1"
    echo "GATEWAY_PORT=4000"
    echo "SECRETS_SOURCE=$1"
    shift
    printf '%s\n' "$@"
  } > "$RAPIDSELECTOR_ENV_FILE"
}

all_secrets_lines() {
  local n
  for n in POSTGRES_PASSWORD LITELLM_MASTER_KEY LITELLM_SALT_KEY LITELLM_UI_PASSWORD \
           RAPIDSELECTOR_OPENROUTER_KEY WEBUI_SECRET_KEY KEY_CHAT KEY_NODE_RED KEY_SMOKE_TEST; do
    echo "$n=v-$n"
  done
}

secrets_service_env() {
  echo test-token > "$BATS_TEST_TMPDIR/token"
  write_env secrets-service "SECRETS_SERVICE_URL=$FAKE_SECRETS_URL" "SECRETS_SERVICE_TOKEN_FILE=$BATS_TEST_TMPDIR/token"
}

blob_json() {
  all_secrets_lines | jq -R 'split("=") | {(.[0]): (.[1:] | join("="))}' | jq -s 'add'
}

@test "env source passes secrets and arguments to docker compose" {
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  run "$REPO/rapidselector.sh" up -d
  [ "$status" -eq 0 ]
  grep -qx "ARGS=compose up -d" "$DOCKER_CALL_LOG"
  for line in "${lines[@]}"; do grep -qxF "$line" "$DOCKER_CALL_LOG"; done
}

@test "up runs detached without being asked" {
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  run "$REPO/rapidselector.sh" up
  [ "$status" -eq 0 ]
  [ "$(grep '^ARGS=' "$DOCKER_CALL_LOG")" = "ARGS=compose up -d" ]
}

@test "up keeps the arguments it is given" {
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  run "$REPO/rapidselector.sh" up gateway
  [ "$status" -eq 0 ]
  [ "$(grep '^ARGS=' "$DOCKER_CALL_LOG")" = "ARGS=compose up -d gateway" ]
}

@test "up -d does not pass the switch twice" {
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  run "$REPO/rapidselector.sh" up -d
  [ "$status" -eq 0 ]
  [ "$(grep '^ARGS=' "$DOCKER_CALL_LOG")" = "ARGS=compose up -d" ]
}

@test "the Compose file sets no memory limit, which hosts without memory control warn about" {
  ! grep -q 'mem_limit' "$REPO/docker-compose.yml"
}

@test "values with \$, quotes and spaces arrive unchanged" {
  mapfile -t lines < <(all_secrets_lines | grep -v '^POSTGRES_PASSWORD=')
  write_env env "${lines[@]}" 'POSTGRES_PASSWORD=a$HOME "b" '"'c'"' d\e'
  run "$REPO/rapidselector.sh" ps
  [ "$status" -eq 0 ]
  grep -qxF 'POSTGRES_PASSWORD=a$HOME "b" '"'c'"' d\e' "$DOCKER_CALL_LOG"
}

@test "secrets-service source exports blob fields" {
  blob_json > "$ARTIFACTS/secrets.json"
  secrets_service_env
  run "$REPO/rapidselector.sh" up -d
  [ "$status" -eq 0 ]
  grep -qx "ARGS=compose up -d" "$DOCKER_CALL_LOG"
  while read -r line; do grep -qxF "$line" "$DOCKER_CALL_LOG"; done < <(all_secrets_lines)
}

@test "missing blob field exits 3 and names the field without calling docker" {
  blob_json | jq 'del(.KEY_NODE_RED)' > "$ARTIFACTS/secrets.json"
  secrets_service_env
  run "$REPO/rapidselector.sh" up -d
  [ "$status" -eq 3 ]
  [[ "$output" == *KEY_NODE_RED* ]]
  [ ! -e "$DOCKER_CALL_LOG" ]
}

@test "secrets-service 401 and 423 and unreachable exit 4 without calling docker" {
  blob_json > "$ARTIFACTS/secrets.json"
  echo wrong-token > "$BATS_TEST_TMPDIR/token"
  write_env secrets-service "SECRETS_SERVICE_URL=$FAKE_SECRETS_URL" "SECRETS_SERVICE_TOKEN_FILE=$BATS_TEST_TMPDIR/token"
  run "$REPO/rapidselector.sh" up -d
  [ "$status" -eq 4 ]
  [[ "$output" == *401* ]]

  secrets_service_env
  curl -sS -X POST "$FAKE_SECRETS_URL/_status" -d '{"status":423}' >/dev/null
  run "$REPO/rapidselector.sh" up -d
  [ "$status" -eq 4 ]
  [[ "$output" == *423* ]]

  write_env secrets-service "SECRETS_SERVICE_URL=http://127.0.0.1:1" "SECRETS_SERVICE_TOKEN_FILE=$BATS_TEST_TMPDIR/token"
  run "$REPO/rapidselector.sh" up -d
  [ "$status" -eq 4 ]
  [[ "$output" == *unreachable* ]]
  [ ! -e "$DOCKER_CALL_LOG" ]
}

@test "unknown SECRETS_SOURCE exits 2" {
  write_env vault
  run "$REPO/rapidselector.sh" up -d
  [ "$status" -eq 2 ]
  [[ "$output" == *"SECRETS_SOURCE must be env or secrets-service"* ]]
  [ ! -e "$DOCKER_CALL_LOG" ]
}

@test "update runs pull then up -d" {
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  run "$REPO/rapidselector.sh" update
  [ "$status" -eq 0 ]
  [ "$(grep '^ARGS=' "$DOCKER_CALL_LOG" | tr '\n' '|')" = "ARGS=compose pull|ARGS=compose up -d|" ]
}

@test "no secret value is printed to stdout or stderr" {
  blob_json | jq 'del(.KEY_CHAT)' > "$ARTIFACTS/secrets.json"
  secrets_service_env
  run "$REPO/rapidselector.sh" up -d
  [ "$status" -eq 3 ]
  [[ "$output" != *v-* ]]
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  run "$REPO/rapidselector.sh" up -d
  [ "$status" -eq 0 ]
  [[ "$output" != *v-* ]]
}
