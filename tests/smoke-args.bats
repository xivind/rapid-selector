#!/usr/bin/env bats
# Level 1: which names scripts/smoke-test.sh calls, tested without the network.
# A stand-in curl plays the gateway: /model/info lists one role and two experiment names,
# every chat call is answered with 200 and a cost, and both probes are refused.

load helpers

setup() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
headers="" data="" url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -D) headers="$2"; shift 2 ;;
    -d) data="$2"; shift 2 ;;
    -o|-w|-X|-H) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */model/info)
    printf '%s\n200' '{"data":[
      {"model_name":"classify","model_info":{"rapidselector_kind":"role","reasoning":false}},
      {"model_name":"llama-3.1-8b-instruct@deepinfra","model_info":{"rapidselector_kind":"experiment","reasoning":false}},
      {"model_name":"gpt-oss-20b@deepinfra","model_info":{"rapidselector_kind":"experiment","reasoning":true}}]}'
    ;;
  */openrouter/*) printf 403 ;;
  */v1/chat/completions)
    if [ -n "$headers" ]; then
      echo "$data" >> "$CALL_LOG"
      printf 'HTTP/1.1 200 OK\r\nx-litellm-response-cost: 0.00001\r\n' > "$headers"
      printf 200
    else
      printf 401
    fi
    ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export CALL_LOG="$BATS_TEST_TMPDIR/calls"
  : > "$CALL_LOG"
  export LITELLM_MASTER_KEY=sk-master KEY_SMOKE_TEST=sk-smoke RAPIDSELECTOR_LAN_ADDRESS=127.0.0.1 GATEWAY_PORT=4000
}

called_models() {
  jq -r .model "$CALL_LOG"
}

@test "without options, only the roles are called" {
  run "$REPO/scripts/smoke-test.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(called_models)" = "classify" ]
}

@test "--name calls only that name, with low effort for a reasoning model" {
  run "$REPO/scripts/smoke-test.sh" --name gpt-oss-20b@deepinfra
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(called_models)" = "gpt-oss-20b@deepinfra" ]
  [ "$(jq -r .reasoning_effort "$CALL_LOG")" = "low" ]
  grep -q '^gpt-oss-20b@deepinfra  *200 0.00001000$' <<<"$output"
  grep -qx "OK" <<<"$output"
}

@test "--name with a name the gateway does not have fails before any call" {
  run "$REPO/scripts/smoke-test.sh" --name gpt-oss-20b@nowhere
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gpt-oss-20b@nowhere"* ]]
  [ ! -s "$CALL_LOG" ]
}

@test "--name without a name fails before any call" {
  run "$REPO/scripts/smoke-test.sh" --name
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--name"* ]]
  [ ! -s "$CALL_LOG" ]
}

@test "an unknown option fails before any call" {
  run "$REPO/scripts/smoke-test.sh" --al
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--al"* ]]
  [ ! -s "$CALL_LOG" ]
}
