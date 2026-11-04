#!/usr/bin/env bats
# Level 1: Open WebUI (chat), driven through its HTTP API, against the gateway and the fake upstream.

load helpers

CHAT_URL="http://127.0.0.1:4010"
FINDINGS="$ARTIFACTS/findings.txt"

setup_file() {
  stack_up
  run_setup_keys >/dev/null
  # The admin account is created once, by the first test; its token is kept for the others.
  rm -f "$ARTIFACTS/chat-admin-token"
}

teardown_file() {
  stack_down
}

setup() {
  upstream_reset
  upstream_mode 200
}

admin_token() {
  cat "$ARTIFACTS/chat-admin-token"
}

signup() {
  curl -sS -w '\n%{http_code}' -X POST "$CHAT_URL/api/v1/auths/signup" -H 'Content-Type: application/json' \
    -d "{\"name\":\"$1\",\"email\":\"$1@example.test\",\"password\":\"Test-password-1\"}"
}

# chat_api <method> <path> [json]: call Open WebUI as the admin; prints the body.
chat_api() {
  local args=(-sS -X "$1" -H "Authorization: Bearer $(admin_token)")
  [ -n "${3:-}" ] && args+=(-H 'Content-Type: application/json' -d "$3")
  curl "${args[@]}" "$CHAT_URL$2"
}

upstream_models() {
  upstream_requests | jq -c '[.[].body.model]'
}

@test "first account is created as admin with signup disabled" {
  response="$(signup admin)"
  [ "${response##*$'\n'}" = "200" ]
  body="${response%$'\n'*}"
  [ "$(jq -r '.role' <<<"$body")" = "admin" ]
  jq -r '.token' <<<"$body" > "$ARTIFACTS/chat-admin-token"
}

@test "second signup is refused" {
  response="$(signup intruder)"
  code="${response##*$'\n'}"
  [ "$code" -ge 400 ] && [ "$code" -lt 500 ]
}

@test "models listed come from the gateway only" {
  models="$(chat_api GET /api/models | jq -c '[.data[].id] | sort')"
  expected="$(curl -sS -H "Authorization: Bearer $(test_env LITELLM_MASTER_KEY)" "$GATEWAY_URL/model/info" \
    | jq -c '[.data[].model_name] | unique | sort')"
  [ "$models" = "$expected" ] || { echo "open webui: $models"; false; }
}

@test "a chat completion goes through the gateway" {
  spend_before="$(key_spend "$(test_env KEY_CHAT)")"
  body="$(chat_api POST /api/chat/completions '{"model":"classify","stream":false,"messages":[{"role":"user","content":"hi"}]}')"
  [ "$(jq -r '.choices[0].message.content' <<<"$body")" = "fake reply" ] || { echo "$body"; false; }
  [ "$(upstream_models)" = '["mistralai/mistral-small-3.2-24b-instruct"]' ]
  wait_for_key_spend_above "$(test_env KEY_CHAT)" "$spend_before"
}

@test "streamed chat records spend on the chat key" {
  spend_before="$(key_spend "$(test_env KEY_CHAT)")"
  run chat_api POST /api/chat/completions '{"model":"summarise","stream":true,"messages":[{"role":"user","content":"hi"}]}'
  [[ "$output" == *"fake reply"* ]]
  wait_for_key_spend_above "$(test_env KEY_CHAT)" "$spend_before"
}

@test "title generation uses llama-3.1-8b-instruct@deepinfra" {
  run chat_api POST /api/v1/tasks/title/completions \
    '{"model":"gpt-oss-120b@deepinfra","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]}'
  echo "$(date -u +%FT%TZ) chat.bats: title task -> upstream models $(upstream_models); response ${output:0:200}" >> "$FINDINGS"
  [ "$(upstream_models)" = '["meta-llama/llama-3.1-8b-instruct"]' ]
}

@test "no tags, follow-up or autocomplete calls reach the upstream" {
  msgs='"messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]'
  chat_api POST /api/v1/tasks/tags/completions "{\"model\":\"classify\",$msgs}" >/dev/null || true
  chat_api POST /api/v1/tasks/follow_up/completions "{\"model\":\"classify\",$msgs}" >/dev/null || true
  chat_api POST /api/v1/tasks/auto/completions '{"model":"classify","prompt":"hel","type":"general"}' >/dev/null || true
  chat_api POST /api/v1/tasks/queries/completions "{\"model\":\"classify\",\"type\":\"web_search\",$msgs}" >/dev/null || true
  [ "$(upstream_requests | jq length)" = "0" ] || { echo "$(upstream_models)"; false; }
}

@test "admin panel changes are not persisted" {
  config="$(chat_api GET /api/v1/auths/admin/config)"
  [ "$(jq -r '.ENABLE_SIGNUP' <<<"$config")" = "false" ]
  chat_api POST /api/v1/auths/admin/config "$(jq -c '.ENABLE_SIGNUP = true' <<<"$config")" >/dev/null
  [ "$(chat_api GET /api/v1/auths/admin/config | jq -r '.ENABLE_SIGNUP')" = "true" ]
  docker restart rapidselector-chat >/dev/null
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' rapidselector-chat)" = "healthy" ] && break
    sleep 3
  done
  [ "$(chat_api GET /api/v1/auths/admin/config | jq -r '.ENABLE_SIGNUP')" = "false" ]
}

@test "chat starts without downloading models" {
  logs="$(docker logs rapidselector-chat 2>&1)"
  mem="$(docker stats --no-stream --format '{{.MemUsage}}' rapidselector-chat | cut -d/ -f1 | tr -d ' ')"
  echo "$(date -u +%FT%TZ) chat.bats: chat memory after start $mem; log lines mentioning downloads: $(grep -ciE 'huggingface|downloading|download' <<<"$logs")" >> "$FINDINGS"
  ! grep -qiE 'huggingface\.co|Downloading' <<<"$logs"
  [[ "$mem" == *MiB ]] && [ "${mem%%.*}" -lt 1024 ] || [[ "$mem" == *KiB ]]
}
