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
           RAPIDSELECTOR_OPENROUTER_KEY WEBUI_SECRET_KEY KEY_CHAT KEY_NODE_RED KEY_SMOKE_TEST \
           OPENROUTER_MANAGEMENT_KEY KEY_SCRIPTS; do
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
           RAPIDSELECTOR_OPENROUTER_KEY WEBUI_SECRET_KEY KEY_CHAT KEY_NODE_RED KEY_SMOKE_TEST \
           OPENROUTER_MANAGEMENT_KEY KEY_SCRIPTS; do
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
  # Every required secret; the optional management key is fetched for run-script only.
  while read -r line; do grep -qxF "$line" "$DOCKER_CALL_LOG"; done < <(all_secrets_lines | grep -v '^OPENROUTER_MANAGEMENT_KEY=')
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

# rules_env [sed expression]: an env file with every secret, and RAPIDSELECTOR_GATEWAY_CONFIG
# pointing at the example config with the expression applied (none: the example itself).
rules_env() {
  sed -e "${1:-}" "$RAPIDSELECTOR_GATEWAY_CONFIG" > "$BATS_TEST_TMPDIR/config.yaml"
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  export RAPIDSELECTOR_GATEWAY_CONFIG="$BATS_TEST_TMPDIR/config.yaml"
}

@test "restart gateway runs the rules check and then docker" {
  rules_env
  run "$REPO/rapidselector.sh" restart gateway
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "^rules ok: $(config_count) entries" <<<"$output"
  [ "$(grep '^ARGS=' "$DOCKER_CALL_LOG")" = "ARGS=compose restart gateway" ]
}

@test "restart gateway with a broken rule exits 5 without calling docker" {
  rules_env '0,/allow_fallbacks: false/s//allow_fallbacks: true/'
  run "$REPO/rapidselector.sh" restart gateway
  echo "$output"
  [ "$status" -eq 5 ]
  grep -q "^FAIL chat-tasks: allow_fallbacks must be false" <<<"$output"
  grep -q "gateway not restarted: config/gateway.yaml or config/home.env breaks a rule" <<<"$output"
  [ ! -e "$DOCKER_CALL_LOG" ]
}

@test "restart with no service checks the rules too" {
  rules_env '0,/allow_fallbacks: false/s//allow_fallbacks: true/'
  run "$REPO/rapidselector.sh" restart
  [ "$status" -eq 5 ]
  [ ! -e "$DOCKER_CALL_LOG" ]
}

@test "restart chat is not checked" {
  rules_env '0,/allow_fallbacks: false/s//allow_fallbacks: true/'
  run "$REPO/rapidselector.sh" restart chat
  [ "$status" -eq 0 ]
  [ "$(grep '^ARGS=' "$DOCKER_CALL_LOG")" = "ARGS=compose restart chat" ]
}

@test "env source: no management key still runs docker" {
  mapfile -t lines < <(all_secrets_lines | grep -v '^OPENROUTER_MANAGEMENT_KEY=')
  write_env env "${lines[@]}" "OPENROUTER_MANAGEMENT_KEY="
  run "$REPO/rapidselector.sh" up
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx "ARGS=compose up -d" "$DOCKER_CALL_LOG"
  grep -qx "OPENROUTER_MANAGEMENT_KEY=" "$DOCKER_CALL_LOG"
}

@test "secrets-service source: no management key field still runs docker" {
  blob_json | jq 'del(.OPENROUTER_MANAGEMENT_KEY)' > "$ARTIFACTS/secrets.json"
  secrets_service_env
  run "$REPO/rapidselector.sh" up
  echo "$output"
  [ "$status" -eq 0 ]
  grep -qx "OPENROUTER_MANAGEMENT_KEY=" "$DOCKER_CALL_LOG"
  grep -qx "KEY_SCRIPTS=v-KEY_SCRIPTS" "$DOCKER_CALL_LOG"
}

@test "secrets-service source: an empty management key field counts as not set" {
  blob_json | jq '.OPENROUTER_MANAGEMENT_KEY = ""' > "$ARTIFACTS/secrets.json"
  secrets_service_env
  run "$REPO/rapidselector.sh" up
  [ "$status" -eq 0 ]
  grep -qx "OPENROUTER_MANAGEMENT_KEY=" "$DOCKER_CALL_LOG"
}

@test "secrets-service source: the management key is fetched for run-script only" {
  blob_json > "$ARTIFACTS/secrets.json"
  secrets_service_env
  run "$REPO/rapidselector.sh" up
  [ "$status" -eq 0 ]
  grep -qx "OPENROUTER_MANAGEMENT_KEY=" "$DOCKER_CALL_LOG"
  run "$REPO/rapidselector.sh" run-script bash -c 'echo "key=${OPENROUTER_MANAGEMENT_KEY:-unset}"'
  [ "$status" -eq 0 ]
  [ "$output" = "key=v-OPENROUTER_MANAGEMENT_KEY" ]
}

@test "secrets-service: a blob that is not an object exits 4 without calling docker" {
  echo '["not", "an", "object"]' > "$ARTIFACTS/secrets.json"
  secrets_service_env
  run "$REPO/rapidselector.sh" up
  echo "$output"
  [ "$status" -eq 4 ]
  [[ "$output" == *"no fields"* ]]
  [ ! -e "$DOCKER_CALL_LOG" ]
}

@test "restart gateway without the config exits 2" {
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  RAPIDSELECTOR_GATEWAY_CONFIG="$BATS_TEST_TMPDIR/missing.yaml" run "$REPO/rapidselector.sh" restart gateway
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"copy config/gateway.example.yaml"* ]]
  [[ "$output" != *"breaks a rule"* ]]
  [ ! -e "$DOCKER_CALL_LOG" ]
}

@test "up without config/gateway.yaml exits 2 and names the example" {
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  RAPIDSELECTOR_GATEWAY_CONFIG="$BATS_TEST_TMPDIR/none.yaml" run "$REPO/rapidselector.sh" up
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR/none.yaml not found: copy config/gateway.example.yaml to config/gateway.yaml"* ]]
  [ ! -e "$DOCKER_CALL_LOG" ]
}

@test "up without config/home.env exits 2 and names the example" {
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  RAPIDSELECTOR_HOME_ENV="$BATS_TEST_TMPDIR/none.env" run "$REPO/rapidselector.sh" up
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"$BATS_TEST_TMPDIR/none.env not found: copy config/home.example.env to config/home.env"* ]]
  [ ! -e "$DOCKER_CALL_LOG" ]
}

@test "a directory named gateway.yaml is refused" {
  # Docker creates one for a missing bind mount source.
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  mkdir "$BATS_TEST_TMPDIR/gateway.yaml"
  RAPIDSELECTOR_GATEWAY_CONFIG="$BATS_TEST_TMPDIR/gateway.yaml" run "$REPO/rapidselector.sh" up
  [ "$status" -eq 2 ]
  [ ! -e "$DOCKER_CALL_LOG" ]
}

@test "run-script runs without config files" {
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  RAPIDSELECTOR_GATEWAY_CONFIG="$BATS_TEST_TMPDIR/none.yaml" RAPIDSELECTOR_HOME_ENV="$BATS_TEST_TMPDIR/none.env" \
    run "$REPO/rapidselector.sh" run-script bash -c 'echo ran'
  [ "$status" -eq 0 ]
  [ "$output" = "ran" ]
}

@test "restart gateway with a broken home.env exits 5" {
  rules_env
  sed 's/^BUDGET_TEAM_EXPERIMENTS=.*/BUDGET_TEAM_EXPERIMENTS=99/' "$RAPIDSELECTOR_HOME_ENV" > "$BATS_TEST_TMPDIR/home.env"
  RAPIDSELECTOR_HOME_ENV="$BATS_TEST_TMPDIR/home.env" run "$REPO/rapidselector.sh" restart gateway
  echo "$output"
  [ "$status" -eq 5 ]
  grep -q "^FAIL home.env: team budgets" <<<"$output"
  grep -q "breaks a rule" <<<"$output"
  [ ! -e "$DOCKER_CALL_LOG" ]
}

@test "setup-keys refuses without home.env, before any gateway call" {
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  printf '#!/usr/bin/env bash\ntouch "%s/curl-called"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  RAPIDSELECTOR_HOME_ENV="$BATS_TEST_TMPDIR/none.env" run "$REPO/rapidselector.sh" run-script "$REPO/scripts/setup-keys.sh"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"copy config/home.example.env"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/curl-called" ]
}

@test "setup-keys refuses a broken rule in home.env, before any gateway call" {
  mapfile -t lines < <(all_secrets_lines)
  write_env env "${lines[@]}"
  printf '#!/usr/bin/env bash\ntouch "%s/curl-called"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  sed 's/^BUDGET_TEAM_EXPERIMENTS=.*/BUDGET_TEAM_EXPERIMENTS=99/' "$RAPIDSELECTOR_HOME_ENV" > "$BATS_TEST_TMPDIR/home.env"
  RAPIDSELECTOR_HOME_ENV="$BATS_TEST_TMPDIR/home.env" run "$REPO/rapidselector.sh" run-script "$REPO/scripts/setup-keys.sh"
  echo "$output"
  [ "$status" -eq 1 ]
  grep -q "^FAIL home.env: team budgets" <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/curl-called" ]
}
