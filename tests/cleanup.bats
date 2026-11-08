#!/usr/bin/env bats
# Level 1: the one-off cleanup scripts for docs/test-procedures/ops-scripts.md, deleted from
# the repository once the owner has run them. The secrets tests need only the fake
# secrets-service; the user tests need the gateway.

load helpers

setup_file() {
  stack_up
}

teardown_file() {
  stack_down
}

PHASE0="POSTGRES_PASSWORD LITELLM_MASTER_KEY LITELLM_SALT_KEY LITELLM_UI_PASSWORD RAPIDSELECTOR_OPENROUTER_KEY
  WEBUI_SECRET_KEY KEY_CHAT KEY_NODE_RED KEY_SMOKE_TEST"
TOWER_FIELDS="TOWER_PASSWORD TOWER_SESSION_SECRET TOWER_GATEWAY_KEY"

setup() {
  curl -sS -X POST "$FAKE_SECRETS_URL/_status" -d '{"status":200}' >/dev/null
  export RAPIDSELECTOR_ENV_FILE="$BATS_TEST_TMPDIR/env"
  echo test-token > "$BATS_TEST_TMPDIR/token"
}

# tower_blob [names...]: a blob with a value "v-<NAME>" for each name (default: the 9 phase 0
# fields, the management key and tower's three).
tower_blob() {
  local names=("$@")
  # shellcheck disable=SC2206
  [ "${#names[@]}" -gt 0 ] || names=($PHASE0 OPENROUTER_MANAGEMENT_KEY $TOWER_FIELDS)
  printf '%s\n' "${names[@]}" | jq -R '{(.): "v-\(.)"}' | jq -sc add
}

# secrets_service_settings: the env file for SECRETS_SOURCE=secrets-service and the fake.
secrets_service_settings() {
  printf '%s\n' "SECRETS_SOURCE=secrets-service" "SECRETS_SERVICE_URL=$FAKE_SECRETS_URL" \
    "SECRETS_SERVICE_TOKEN_FILE=$BATS_TEST_TMPDIR/token" > "$RAPIDSELECTOR_ENV_FILE"
}

stored() {
  cat "$ARTIFACTS/secrets.json"
}

@test "secrets: adds KEY_SCRIPTS and removes the three tower fields, keeping the rest" {
  tower_blob > "$ARTIFACTS/secrets.json"
  secrets_service_settings
  run "$REPO/scripts/cleanup-tower-secrets.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(stored | jq length)" = "11" ]
  for name in $PHASE0 OPENROUTER_MANAGEMENT_KEY; do
    [ "$(stored | jq -r --arg n "$name" '.[$n]')" = "v-$name" ] || { echo "changed: $name"; false; }
  done
  for name in $TOWER_FIELDS; do
    [ "$(stored | jq --arg n "$name" 'has($n)')" = "false" ] || { echo "still there: $name"; false; }
  done
  [[ "$(stored | jq -r .KEY_SCRIPTS)" =~ ^sk-[0-9a-f]{48}$ ]]
}

@test "secrets: a second run changes nothing" {
  tower_blob > "$ARTIFACTS/secrets.json"
  secrets_service_settings
  run "$REPO/scripts/cleanup-tower-secrets.sh"
  [ "$status" -eq 0 ]
  first="$(stored)"
  run "$REPO/scripts/cleanup-tower-secrets.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(stored)" = "$first" ]
  [[ "$output" == *"nothing to change"* ]]
}

@test "secrets: fewer than 9 fields is refused with exit 4 and nothing written" {
  tower_blob POSTGRES_PASSWORD LITELLM_MASTER_KEY TOWER_PASSWORD > "$ARTIFACTS/secrets.json"
  before="$(stored)"
  secrets_service_settings
  run "$REPO/scripts/cleanup-tower-secrets.sh"
  echo "$output"
  [ "$status" -eq 4 ]
  [ "$(stored)" = "$before" ]
}

@test "secrets: env mode writes nothing and names the lines" {
  echo '{}' > "$ARTIFACTS/secrets.json"
  {
    echo "SECRETS_SOURCE=env"
    echo "TOWER_PORT=4020"
    for name in $PHASE0 OPENROUTER_MANAGEMENT_KEY $TOWER_FIELDS; do echo "$name=v-$name"; done
  } > "$RAPIDSELECTOR_ENV_FILE"
  before="$(cat "$RAPIDSELECTOR_ENV_FILE")"
  run "$REPO/scripts/cleanup-tower-secrets.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$RAPIDSELECTOR_ENV_FILE")" = "$before" ]
  [ "$(stored)" = "{}" ]
  for name in $TOWER_FIELDS TOWER_PORT KEY_SCRIPTS; do
    grep -q "$name" <<<"$output" || { echo "not named: $name"; false; }
  done
  # It says how to make the value, and prints none.
  [[ "$output" == *'openssl rand -hex 24'* ]]
  ! grep -qE 'sk-[0-9a-f]{48}' <<<"$output"
}

@test "secrets: output shows names and lengths, no value" {
  tower_blob > "$ARTIFACTS/secrets.json"
  secrets_service_settings
  run "$REPO/scripts/cleanup-tower-secrets.sh"
  [ "$status" -eq 0 ]
  grep -qx "KEY_SCRIPTS 51" <<<"$output"
  grep -qx "POSTGRES_PASSWORD 19" <<<"$output"
  [[ "$output" != *"v-"* ]]
  [[ "$output" != *"$(stored | jq -r .KEY_SCRIPTS)"* ]]
}

# master <method> <path> [json]: call the gateway with the master key; prints the body.
master() {
  curl -sS -X "$1" -H "Authorization: Bearer $(test_env LITELLM_MASTER_KEY)" \
    -H 'Content-Type: application/json' ${3:+-d "$3"} "$GATEWAY_URL$2"
}

tower_aliases() {
  master GET '/key/list?return_full_object=true&size=100' | jq '[.keys[] | select(.key_alias == "tower")] | length'
}

@test "user: removes user tower and its key" {
  master POST /user/new '{"user_id":"tower","user_alias":"tower","user_role":"proxy_admin","auto_create_key":false}' >/dev/null
  master POST /key/generate '{"key_alias":"tower","user_id":"tower"}' >/dev/null
  [ "$(tower_aliases)" = "1" ]
  run bash -c 'cd "$REPO" && RAPIDSELECTOR_ENV_FILE="$TEST_ENV_FILE" ./rapidselector.sh run-script scripts/cleanup-tower-user.sh'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed"* ]]
  [ "$(tower_aliases)" = "0" ]
  user="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(test_env LITELLM_MASTER_KEY)" \
    "$GATEWAY_URL/user/info?user_id=tower")"
  [ "$user" = "404" ] || [ "$(master GET '/user/info?user_id=tower' | jq '.user_info == null')" = "true" ]
}

@test "user: a second run exits 0" {
  run bash -c 'cd "$REPO" && RAPIDSELECTOR_ENV_FILE="$TEST_ENV_FILE" ./rapidselector.sh run-script scripts/cleanup-tower-user.sh'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to remove"* ]]
}
