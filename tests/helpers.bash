# Shared helpers for the level 1 bats tests. Load with `load helpers`.
# shellcheck shell=bash

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$REPO/tests/.artifacts"
TEST_ENV_FILE="$ARTIFACTS/test.env"
FAKE_UPSTREAM_URL="http://127.0.0.1:18000"
FAKE_SECRETS_URL="http://127.0.0.1:18002"
GATEWAY_PORT="${GATEWAY_PORT:-4000}"
GATEWAY_URL="http://127.0.0.1:${GATEWAY_PORT}"
export REPO ARTIFACTS TEST_ENV_FILE FAKE_UPSTREAM_URL FAKE_SECRETS_URL GATEWAY_PORT GATEWAY_URL

mkdir -p "$ARTIFACTS"

# RAPIDSELECTOR_SECRETS: the secret names the test env file gets random values for.
# shellcheck source=SCRIPTDIR/../scripts/lib.sh
. "$REPO/scripts/lib.sh"

# Write tests/.artifacts/test.env with test settings and random secrets, unless it exists.
ensure_test_env() {
  [ -f "$TEST_ENV_FILE" ] && return 0
  {
    echo "RAPIDSELECTOR_LAN_ADDRESS=127.0.0.1"
    echo "GATEWAY_PORT=${GATEWAY_PORT}"
    echo "CHAT_PORT=4010"
    echo "SECRETS_SOURCE=env"
    local name
    for name in "${RAPIDSELECTOR_SECRETS[@]}"; do
      case "$name" in
        KEY_*) echo "$name=sk-test-$(openssl rand -hex 16)" ;;
        *) echo "$name=$(openssl rand -hex 24)" ;;
      esac
    done
  } > "$TEST_ENV_FILE"
}

# Read one value from the test env file.
test_env() {
  grep -m1 "^$1=" "$TEST_ENV_FILE" | cut -d= -f2-
}

# docker compose with the fakes overlay only (no gateway stack).
compose_fakes() {
  docker compose --project-directory "$REPO" -f "$REPO/tests/compose.fakes.yml" "$@"
}

fakes_up() {
  [ -f "$ARTIFACTS/secrets.json" ] || echo '{}' > "$ARTIFACTS/secrets.json"
  compose_fakes up -d --wait fake-upstream fake-secrets >/dev/null
}

fakes_down() {
  compose_fakes down -v >/dev/null 2>&1 || true
}

# Start the full test stack, with optional overlay files (paths relative to the repository).
stack_up() {
  ensure_test_env
  [ -f "$ARTIFACTS/secrets.json" ] || echo '{}' > "$ARTIFACTS/secrets.json"
  local files=(-f "$REPO/docker-compose.yml" -f "$REPO/tests/compose.fakes.yml" -f "$REPO/tests/compose.test.yml")
  local overlay
  for overlay in "$@"; do files+=(-f "$REPO/$overlay"); done
  if [ -x "$REPO/rapidselector.sh" ]; then
    (cd "$REPO" && RAPIDSELECTOR_ENV_FILE="$TEST_ENV_FILE" ./rapidselector.sh "${files[@]}" up -d --build --wait)
  else
    docker compose --project-directory "$REPO" --env-file "$TEST_ENV_FILE" "${files[@]}" up -d --build --wait
  fi
}

stack_down() {
  docker compose --project-directory "$REPO" --env-file "$TEST_ENV_FILE" \
    -f "$REPO/docker-compose.yml" -f "$REPO/tests/compose.fakes.yml" -f "$REPO/tests/compose.test.yml" down -v >/dev/null 2>&1 || true
}

upstream_requests() {
  curl -sS "$FAKE_UPSTREAM_URL/_requests"
}

upstream_reset() {
  curl -sS -X DELETE "$FAKE_UPSTREAM_URL/_requests" >/dev/null
}

# upstream_mode <status> [cost] [delay_ms]
upstream_mode() {
  local cost="${2:-null}" delay="${3:-0}"
  curl -sS -X POST "$FAKE_UPSTREAM_URL/_mode" \
    -d "{\"status\":$1,\"cost\":$cost,\"delay_ms\":$delay}" >/dev/null
}

# gw_call <key> <model> [extra_json]
# Sets $output (body), $GW_STATUS (HTTP status) and $GW_COST (x-litellm-response-cost).
gw_call() {
  local key="$1" model="$2" extra="${3:-{\}}" headers
  headers="$(mktemp)"
  local body
  body="$(jq -nc --arg m "$model" --argjson x "$extra" \
    '{model:$m, messages:[{role:"user",content:"Reply with the word ok."}]} + $x')"
  output="$(curl -sS -D "$headers" -o - -w '\n%{http_code}' -X POST "$GATEWAY_URL/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' -d "$body")"
  GW_STATUS="${output##*$'\n'}"
  output="${output%$'\n'*}"
  GW_COST="$(grep -i '^x-litellm-response-cost:' "$headers" | tail -1 | cut -d: -f2- | tr -d ' \r')"
  rm -f "$headers"
  export GW_STATUS GW_COST
}

# metric <name> [label_regex]: sum of the matching samples on the gateway's /metrics.
metric() {
  curl -sS "$GATEWAY_URL/metrics/" \
    | grep -E "^$1(\{[^}]*\})? " \
    | grep -E "${2:-.}" \
    | awk '{ s += $NF } END { printf "%.10g\n", s + 0 }'
}

# run_setup_keys [VAR=value...]: run scripts/setup-keys.sh through rapidselector.sh with the
# test settings; extra assignments (e.g. BUDGET_KEY_SMOKE_TEST=0.03) go into its environment.
run_setup_keys() {
  (cd "$REPO" && env "$@" RAPIDSELECTOR_ENV_FILE="$TEST_ENV_FILE" ./rapidselector.sh run-script scripts/setup-keys.sh)
}

# key_info <key value>: LiteLLM's /key/info for that key, as JSON (master key).
key_info() {
  curl -sS -G -H "Authorization: Bearer $(test_env LITELLM_MASTER_KEY)" \
    --data-urlencode "key=$1" "$GATEWAY_URL/key/info"
}

# team_info <team id>: LiteLLM's /team/info, as JSON (master key).
team_info() {
  curl -sS -G -H "Authorization: Bearer $(test_env LITELLM_MASTER_KEY)" \
    --data-urlencode "team_id=$1" "$GATEWAY_URL/team/info"
}

# fake_tokens <prompt> <completion>: make every upstream answer report these token counts.
fake_tokens() {
  curl -sS -X POST "$FAKE_UPSTREAM_URL/_mode" \
    -d "{\"status\":200,\"prompt_tokens\":$1,\"completion_tokens\":$2}" >/dev/null
}

# run_smoke_test [args...]: run scripts/smoke-test.sh through rapidselector.sh with the test settings.
run_smoke_test() {
  (cd "$REPO" && RAPIDSELECTOR_ENV_FILE="$TEST_ENV_FILE" ./rapidselector.sh run-script scripts/smoke-test.sh "$@")
}
