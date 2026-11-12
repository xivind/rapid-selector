#!/usr/bin/env bats
# Level 1: the allowlist and the gateway's behaviour, against the fake upstream.

load helpers

# The example config's entries (config/gateway.example.yaml).
# name|openrouter model|endpoint slug|input $/token|output $/token|default max_tokens|kind|reasoning
ENTRIES='chat-tasks|meta-llama/llama-3.1-8b-instruct|deepinfra/fp8|0.00000002|0.00000004|2048|role|false
gpt-oss-120b@coreweave|openai/gpt-oss-120b|coreweave/fp4|0.00000003|0.00000017|8192|experiment|true
qwen3.8-2.4t-a95b@siliconflow|qwen/qwen3.8-2.4t-a95b|siliconflow/fp8|0.000002|0.000006|8192|experiment|true'

FINDINGS="$ARTIFACTS/findings.txt"

setup_file() {
  stack_up
}

teardown_file() {
  stack_down
}

setup() {
  MASTER="$(test_env LITELLM_MASTER_KEY)"
  upstream_reset
  upstream_mode 200
}

# The last request the fake upstream received.
last_body() {
  upstream_requests | jq '.[-1].body'
}

finding() {
  echo "$(date -u +%FT%TZ) gateway.bats: $*" >> "$FINDINGS"
}

@test "every name answers" {
  while IFS='|' read -r name _; do
    gw_call "$MASTER" "$name"
    [ "$GW_STATUS" = "200" ] || { echo "$name -> $GW_STATUS $output"; false; }
  done <<<"$ENTRIES"
}

@test "provider object reaches the upstream unchanged" {
  while IFS='|' read -r name _ slug _; do
    upstream_reset
    gw_call "$MASTER" "$name"
    expected="$(jq -cn --arg s "$slug" '{order:[$s],only:[$s],allow_fallbacks:false,zdr:true,data_collection:"deny"}')"
    actual="$(last_body | jq -c '.provider')"
    [ "$actual" = "$expected" ] || { echo "$name: $actual"; false; }
  done <<<"$ENTRIES"
}

@test "model sent upstream is the pinned openrouter model" {
  while IFS='|' read -r name model _; do
    upstream_reset
    gw_call "$MASTER" "$name"
    [ "$(last_body | jq -r '.model')" = "$model" ] || { echo "$name: $(last_body | jq -r '.model')"; false; }
  done <<<"$ENTRIES"
}

@test "default max_tokens is applied" {
  while IFS='|' read -r name _ _ _ _ max_tokens _; do
    upstream_reset
    gw_call "$MASTER" "$name"
    [ "$(last_body | jq -r '.max_tokens')" = "$max_tokens" ] || { echo "$name: $(last_body | jq -r '.max_tokens')"; false; }
  done <<<"$ENTRIES"
}

@test "client max_tokens behaviour is recorded" {
  gw_call "$MASTER" chat-tasks '{"max_tokens":50000}'
  [ "$GW_STATUS" = "200" ]
  finding "client max_tokens 50000 on chat-tasks -> upstream received max_tokens=$(last_body | jq -r '.max_tokens')"
}

@test "a model outside the allowlist is refused" {
  for model in openai/gpt-4o openrouter/openai/gpt-4o openrouter/anthropic/claude-3.5-sonnet deepinfra/meta-llama/llama-3.1-8b-instruct; do
    upstream_reset
    gw_call "$MASTER" "$model"
    [ "$GW_STATUS" -ge 400 ] && [ "$GW_STATUS" -lt 500 ] || { echo "$model -> $GW_STATUS"; false; }
    [ "$(upstream_requests | jq 'length')" = "0" ]
  done
}

@test "an underlying model string resolves to its pinned entry" {
  upstream_reset
  gw_call "$MASTER" openrouter/openai/gpt-oss-120b
  provider="$(last_body | jq -c '.provider')"
  finding "master key with openrouter/openai/gpt-oss-120b -> HTTP $GW_STATUS, provider $provider"
  [ "$GW_STATUS" = "200" ]
  [ "$(last_body | jq -r '.provider.zdr')" = "true" ]
  [ "$(last_body | jq -r '.provider.allow_fallbacks')" = "false" ]
}

@test "openrouter pass-through with the master key forwards no usable key" {
  run curl -sS -o /dev/null -w '%{http_code}' -X POST "$GATEWAY_URL/openrouter/v1/chat/completions" \
    -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
    -d '{"model":"openai/gpt-oss-120b","messages":[{"role":"user","content":"hi"}]}'
  auth="$(upstream_requests | jq -r '.[-1].headers.Authorization // .[-1].headers.authorization // "none"')"
  finding "pass-through with master key: HTTP $output, requests at upstream $(upstream_requests | jq length), Authorization header '${auth:0:12}...'"
  [ "$auth" != "Bearer $(test_env RAPIDSELECTOR_OPENROUTER_KEY)" ]
}

@test "model info lists every name with its kind and reasoning flag" {
  info="$(curl -sS -H "Authorization: Bearer $MASTER" "$GATEWAY_URL/model/info")"
  [ "$(jq '[.data[].model_name] | unique | length' <<<"$info")" = "$(config_count)" ]
  [ "$(jq '[.data[] | select(.model_info.rapidselector_kind == "role")] | length' <<<"$info")" = "$(config_roles | wc -l)" ]
  while IFS='|' read -r name _ _ _ _ _ kind reasoning; do
    entry="$(jq -c --arg n "$name" '.data[] | select(.model_name == $n) | .model_info' <<<"$info")"
    [ "$(jq -r '.rapidselector_kind' <<<"$entry")" = "$kind" ] || { echo "$name kind"; false; }
    [ "$(jq -r '.reasoning' <<<"$entry")" = "$reasoning" ] || { echo "$name reasoning"; false; }
  done <<<"$ENTRIES"
}

@test "reasoning effort reaches the upstream for qwen3.8" {
  gw_call "$MASTER" qwen3.8-2.4t-a95b@siliconflow
  body="$(last_body)"
  effort="$(jq -r '.reasoning_effort // .reasoning.effort // empty' <<<"$body")"
  finding "qwen3.8 reasoning effort form: $(jq -c '{reasoning_effort, reasoning}' <<<"$body")"
  [ "$effort" = "medium" ]
}

@test "spend is above zero without upstream cost" {
  gw_call "$MASTER" chat-tasks
  expected="$(awk 'BEGIN { printf "%.10f", 100 * 0.00000002 + 50 * 0.00000004 }')"
  [ "$(awk -v a="$GW_COST" -v b="$expected" 'BEGIN { d = a - b; if (d < 0) d = -d; print (a > 0 && d < 1e-12) ? "yes" : "no" }')" = "yes" ] \
    || { echo "cost $GW_COST, expected $expected"; false; }
}

@test "every name records cost above zero without upstream cost" {
  while IFS='|' read -r name _ _ in_price out_price _; do
    gw_call "$MASTER" "$name"
    expected="$(awk -v i="$in_price" -v o="$out_price" 'BEGIN { printf "%.12f", 100 * i + 50 * o }')"
    ok="$(awk -v a="$GW_COST" -v b="$expected" 'BEGIN { d = a - b; if (d < 0) d = -d; print (a > 0 && d < 1e-12) ? "yes" : "no" }')"
    [ "$ok" = "yes" ] || { echo "$name: cost $GW_COST, expected $expected"; false; }
  done <<<"$ENTRIES"
}

@test "spend source with upstream cost is recorded" {
  upstream_mode 200 0.01
  gw_call "$MASTER" chat-tasks
  finding "upstream reported cost 0.01 for chat-tasks; LiteLLM x-litellm-response-cost=$GW_COST (configured price gives 0.000004)"
  [ -n "$GW_COST" ]
}

@test "a streamed call records spend" {
  upstream_mode 200
  run curl -sS -N -X POST "$GATEWAY_URL/v1/chat/completions" -H "Authorization: Bearer $MASTER" \
    -H 'Content-Type: application/json' \
    -d '{"model":"gpt-oss-120b@coreweave","stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"hi"}]}'
  [[ "$output" == *"data: [DONE]"* ]]
  spend=0
  for _ in $(seq 1 20); do
    logs="$(curl -sS -H "Authorization: Bearer $MASTER" "$GATEWAY_URL/spend/logs?summarize=false" )"
    spend="$(jq '[.[] | select(.model_group == "gpt-oss-120b@coreweave") | .spend] | add // 0' <<<"$logs")"
    [ "$(awk -v s="$spend" 'BEGIN { print (s > 0) ? "yes" : "no" }')" = "yes" ] && break
    sleep 2
  done
  finding "streamed gpt-oss-120b@coreweave call: spend log total for gpt-oss-120b@coreweave = $spend"
  [ "$(awk -v s="$spend" 'BEGIN { print (s > 0) ? "yes" : "no" }')" = "yes" ]
}

@test "metrics answer without a key and contain the alert metrics" {
  gw_call "$MASTER" chat-tasks
  run curl -sS -o "$BATS_TEST_TMPDIR/metrics" -w '%{http_code}' "$GATEWAY_URL/metrics/"
  [ "$output" = "200" ]
  for m in litellm_spend_metric litellm_proxy_total_requests_metric litellm_proxy_failed_requests_metric litellm_deployment_failure_responses litellm_postgres_total_requests_total; do
    grep -q "^$m" "$BATS_TEST_TMPDIR/metrics" || { echo "missing $m"; false; }
  done
  finding "metrics present: $(grep -oE '^litellm_[a-z_]+' "$BATS_TEST_TMPDIR/metrics" | sort -u | tr '\n' ' ')"
}
