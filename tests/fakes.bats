#!/usr/bin/env bats
# Level 1: the fake upstream and the fake secrets-service on their own.

load helpers

setup_file() {
  fakes_up
}

teardown_file() {
  fakes_down
}

setup() {
  upstream_reset
  upstream_mode 200
}

@test "fake upstream answers chat completions with usage" {
  run curl -sS -X POST "$FAKE_UPSTREAM_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"openai/gpt-oss-120b","messages":[{"role":"user","content":"hi"}]}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.model' <<<"$output")" = "openai/gpt-oss-120b" ]
  [ "$(jq -r '.choices[0].message.content' <<<"$output")" = "fake reply" ]
  [ "$(jq -r '.usage.prompt_tokens' <<<"$output")" = "100" ]
  [ "$(jq -r '.usage.completion_tokens' <<<"$output")" = "50" ]
  [ "$(jq -r '.usage.total_tokens' <<<"$output")" = "150" ]
  [ "$(jq -r '.usage | has("cost")' <<<"$output")" = "false" ]
}

@test "fake upstream includes cost only when the mode sets it" {
  upstream_mode 200 0.02
  run curl -sS -X POST "$FAKE_UPSTREAM_URL/v1/chat/completions" -d '{"model":"m","messages":[]}'
  [ "$(jq -r '.usage.cost' <<<"$output")" = "0.02" ]
}

@test "fake upstream streams with a final usage chunk" {
  upstream_mode 200 0.01
  run curl -sS -N -X POST "$FAKE_UPSTREAM_URL/v1/chat/completions" \
    -d '{"model":"m","stream":true,"messages":[]}'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"content": "fake reply"'* || "$output" == *'"content":"fake reply"'* ]]
  last_json=$(grep '^data: {' <<<"$output" | tail -1 | sed 's/^data: //')
  [ "$(jq -r '.usage.total_tokens' <<<"$last_json")" = "150" ]
  [ "$(jq -r '.usage.cost' <<<"$last_json")" = "0.01" ]
  [ "$(grep '^data: ' <<<"$output" | tail -1)" = "data: [DONE]" ]
}

@test "fake upstream records requests" {
  curl -sS -X POST "$FAKE_UPSTREAM_URL/v1/chat/completions" \
    -H 'Authorization: Bearer abc' \
    -d '{"model":"m1","provider":{"only":["x"]},"messages":[]}' >/dev/null
  run upstream_requests
  [ "$(jq 'length' <<<"$output")" = "1" ]
  [ "$(jq -r '.[0].path' <<<"$output")" = "/v1/chat/completions" ]
  [ "$(jq -r '.[0].body.provider.only[0]' <<<"$output")" = "x" ]
  [ "$(jq -r '.[0].headers.Authorization // .[0].headers.authorization' <<<"$output")" = "Bearer abc" ]
  upstream_reset
  run upstream_requests
  [ "$(jq 'length' <<<"$output")" = "0" ]
}

@test "fake upstream switches to 402" {
  upstream_mode 402
  run curl -sS -o /dev/null -w '%{http_code}' -X POST "$FAKE_UPSTREAM_URL/v1/chat/completions" -d '{"model":"m","messages":[]}'
  [ "$output" = "402" ]
  run curl -sS -X POST "$FAKE_UPSTREAM_URL/v1/chat/completions" -d '{"model":"m","messages":[]}'
  [ "$(jq -r '.error.code' <<<"$output")" = "402" ]
}

@test "fake upstream fails after N calls" {
  curl -sS -X POST "$FAKE_UPSTREAM_URL/_mode" -d '{"status":200,"fail_after":2}' >/dev/null
  codes=""
  for _ in 1 2 3 4; do
    codes+="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$FAKE_UPSTREAM_URL/v1/chat/completions" -d '{"model":"m","messages":[]}') "
  done
  [ "$codes" = "200 200 402 402 " ]
}

@test "fake upstream uses the configured token counts" {
  curl -sS -X POST "$FAKE_UPSTREAM_URL/_mode" -d '{"status":200,"prompt_tokens":7,"completion_tokens":100000}' >/dev/null
  run curl -sS -X POST "$FAKE_UPSTREAM_URL/v1/chat/completions" -d '{"model":"m","messages":[]}'
  [ "$(jq -r '.usage.prompt_tokens' <<<"$output")" = "7" ]
  [ "$(jq -r '.usage.completion_tokens' <<<"$output")" = "100000" ]
  [ "$(jq -r '.usage.total_tokens' <<<"$output")" = "100007" ]
}

@test "fake secrets-service returns blob with valid token and 401 otherwise" {
  echo '{"POSTGRES_PASSWORD":"p$ss word"}' > "$ARTIFACTS/secrets.json"
  run curl -sS -H 'Authorization: Bearer test-token' "$FAKE_SECRETS_URL/secrets/rapidselector"
  [ "$(jq -r '.name' <<<"$output")" = "rapidselector" ]
  [ "$(jq -r '.blob.POSTGRES_PASSWORD' <<<"$output")" = 'p$ss word' ]
  run curl -sS -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong' "$FAKE_SECRETS_URL/secrets/rapidselector"
  [ "$output" = "401" ]
  curl -sS -X POST "$FAKE_SECRETS_URL/_status" -d '{"status":423}' >/dev/null
  run curl -sS -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer test-token' "$FAKE_SECRETS_URL/secrets/rapidselector"
  [ "$output" = "423" ]
  curl -sS -X POST "$FAKE_SECRETS_URL/_status" -d '{"status":200}' >/dev/null
}
