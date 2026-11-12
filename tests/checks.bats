#!/usr/bin/env bats
# Level 1: the two checkers, tested without the network: check-prices.sh against a saved
# endpoint list, check-arm64.sh with a stand-in docker. The live checks are run by hand
# (README, "For developers"), because Docker Hub's rate limit and hosts' price changes
# must not break the regression suite.

load helpers

setup() {
  # An endpoint list that matches the gateway config exactly, built from the config itself.
  awk '
    /^[[:space:]]*- model_name:/ { if (m != "") print m, i, o, s; m = i = o = s = "" }
    /^[[:space:]]*model: openrouter\// { m = substr($2, 12) }
    /^[[:space:]]*input_cost_per_token:/ { i = $2 }
    /^[[:space:]]*output_cost_per_token:/ { o = $2 }
    /^[[:space:]]*order:/ { s = $2; gsub(/[\[\]"]/, "", s) }
    END { print m, i, o, s }
  ' "$RAPIDSELECTOR_GATEWAY_CONFIG" \
    | jq -R 'split(" ") | {model_id: .[0], tag: .[3], service_tier: null, pricing: {prompt: (.[1] | tonumber | tostring), completion: (.[2] | tonumber | tostring)}}' \
    | jq -s '{data: .}' > "$BATS_TEST_TMPDIR/zdr.json"
  export ZDR_ENDPOINTS_FILE="$BATS_TEST_TMPDIR/zdr.json"

  # A stand-in docker: arm64 for every image except those containing "amd64-only".
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
image="${@: -1}"
echo "Name: $image"
echo "  Platform:    linux/amd64"
[[ "$image" == *amd64-only* ]] || echo "  Platform:    linux/arm64/v8"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "check-prices passes when every entry matches" {
  run "$REPO/scripts/check-prices.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ok ' <<<"$output")" = "$(config_count)" ]
}

@test "check-prices fails when a configured price differs" {
  sed 's/output_cost_per_token: 0.00000004$/output_cost_per_token: 0.0000009/' "$RAPIDSELECTOR_GATEWAY_CONFIG" > "$BATS_TEST_TMPDIR/config.yaml"
  run "$REPO/scripts/check-prices.sh" "$BATS_TEST_TMPDIR/config.yaml"
  [ "$status" -eq 1 ]
  grep -q "^FAIL chat-tasks" <<<"$output"
}

@test "check-prices fails when a pinned endpoint does not exist" {
  sed 's#order: \["coreweave/fp4"\]#order: ["nowhere/fp8"]#' "$RAPIDSELECTOR_GATEWAY_CONFIG" > "$BATS_TEST_TMPDIR/config.yaml"
  run "$REPO/scripts/check-prices.sh" "$BATS_TEST_TMPDIR/config.yaml"
  [ "$status" -eq 1 ]
  grep -q "^FAIL gpt-oss-120b@coreweave" <<<"$output"
}

@test "check-prices fails for an endpoint in the flex tier" {
  jq '.data[0].service_tier = "flex"' "$ZDR_ENDPOINTS_FILE" > "$BATS_TEST_TMPDIR/flex.json"
  ZDR_ENDPOINTS_FILE="$BATS_TEST_TMPDIR/flex.json" run "$REPO/scripts/check-prices.sh"
  [ "$status" -eq 1 ]
  grep -q "flex tier" <<<"$output"
}

@test "check-prices fails for an endpoint with Safety Retention" {
  jq '.data[0].safety_retention = true' "$ZDR_ENDPOINTS_FILE" > "$BATS_TEST_TMPDIR/retention.json"
  ZDR_ENDPOINTS_FILE="$BATS_TEST_TMPDIR/retention.json" run "$REPO/scripts/check-prices.sh"
  [ "$status" -eq 1 ]
  grep -q "Safety Retention" <<<"$output"
}

@test "check-arm64 passes for the pinned images" {
  run "$REPO/tests/check-arm64.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  for image in postgres:17.11-alpine ghcr.io/berriai/litellm-database:v1.106.6 ghcr.io/open-webui/open-webui:v0.13.0-slim python:3.15.2-alpine3.24; do
    grep -qx "ok $image" <<<"$output" || { echo "no line for $image"; false; }
  done
}

@test "check-arm64 fails for an image without arm64" {
  printf 'services:\n  x:\n    image: example/amd64-only:1.0\n' > "$BATS_TEST_TMPDIR/compose.yml"
  run "$REPO/tests/check-arm64.sh" "$BATS_TEST_TMPDIR/compose.yml"
  [ "$status" -eq 1 ]
  grep -q "MISSING linux/arm64: example/amd64-only:1.0" <<<"$output"
}

# broken_config <sed expression>: $BATS_TEST_TMPDIR/config.yaml is the gateway config with the
# expression applied to the first entry (chat-tasks) only.
broken_config() {
  local second
  second="$(grep -n -- '- model_name:' "$RAPIDSELECTOR_GATEWAY_CONFIG" | sed -n 2p | cut -d: -f1)"
  sed -e "1,$((second - 1)){" -e "$1" -e "}" "$RAPIDSELECTOR_GATEWAY_CONFIG" > "$BATS_TEST_TMPDIR/config.yaml"
  ! cmp -s "$RAPIDSELECTOR_GATEWAY_CONFIG" "$BATS_TEST_TMPDIR/config.yaml"
}

# rules_fail <text>: the rules check failed on chat-tasks with a FAIL line holding <text>.
rules_fail() {
  run "$REPO/scripts/check-prices.sh" --rules-only "$BATS_TEST_TMPDIR/config.yaml"
  echo "$output"
  [ "$status" -eq 1 ]
  grep -q "^FAIL chat-tasks: .*$1" <<<"$output"
}

@test "rules: the example passes" {
  # No network: a curl that is called leaves a mark, and no saved endpoint list is given.
  unset ZDR_ENDPOINTS_FILE
  printf '#!/usr/bin/env bash\ntouch "%s/curl-called"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/curl"
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  run "$REPO/scripts/check-prices.sh" --rules-only
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^FAIL' <<<"$output")" = "0" ]
  grep -q "^rules ok: $(config_count) entries" <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/curl-called" ]
}

@test "the config owns store_prompts_in_spend_logs, set to false" {
  # Declared in the file, the setting is the file's: LiteLLM v1.106.6 ignores the admin UI's
  # "Store Prompts in Spend Logs" switch (owned_by_config), so no click stores chat contents.
  run sed -n '/^general_settings:/,/^[^ #]/p' "$RAPIDSELECTOR_GATEWAY_CONFIG"
  grep -qx '  store_prompts_in_spend_logs: false' <<<"$output"
}

@test "rules: fallbacks on" {
  broken_config 's/allow_fallbacks: false/allow_fallbacks: true/'
  rules_fail "allow_fallbacks must be false"
}

@test "rules: zero data retention off" {
  broken_config 's/zdr: true/zdr: false/'
  rules_fail "zdr must be true"
}

@test "rules: data collection allowed" {
  broken_config 's/data_collection: deny/data_collection: allow/'
  rules_fail "data_collection must be deny"
}

@test "rules: order and only differ" {
  broken_config 's#only: \["deepinfra/fp8"\]#only: ["deepinfra/bf16"]#'
  rules_fail "only must equal order"
}

@test "rules: more than one host in order" {
  broken_config 's#order: \["deepinfra/fp8"\]#order: ["deepinfra/bf16", "coreweave/fp4"]#'
  rules_fail "order must name exactly one endpoint"
}

@test "rules: host not allowed" {
  broken_config 's#deepinfra/fp8#novita/fp8#g'
  rules_fail "host novita is not an allowed provider"
}

@test "rules: price zero" {
  broken_config 's/input_cost_per_token: .*/input_cost_per_token: 0/'
  rules_fail "input_cost_per_token must be above zero"
}

@test "rules: no max_tokens" {
  broken_config '/max_tokens:/d'
  rules_fail "cannot read max_tokens"
}

@test "rules: the allowed providers come from home.env" {
  sed 's/^ALLOWED_HOSTS=.*/ALLOWED_HOSTS=deepinfra siliconflow/' "$RAPIDSELECTOR_HOME_ENV" > "$BATS_TEST_TMPDIR/home.env"
  RAPIDSELECTOR_HOME_ENV="$BATS_TEST_TMPDIR/home.env" run "$REPO/scripts/check-prices.sh" --rules-only "$RAPIDSELECTOR_GATEWAY_CONFIG"
  echo "$output"
  [ "$status" -eq 1 ]
  grep -q "^FAIL gpt-oss-120b@coreweave: host coreweave is not an allowed provider" <<<"$output"
}

@test "rules: a :free model" {
  broken_config 's#model: openrouter/\(.*\)$#model: openrouter/\1:free#'
  rules_fail ":free model"
}

@test "rules: a wildcard model" {
  broken_config 's#model: openrouter/.*$#model: openrouter/*#'
  rules_fail "wildcard"
}

@test "rules: a field that cannot be read fails closed" {
  broken_config '/only:/d'
  rules_fail "cannot read only"
}

@test "prices still checked after the rules" {
  broken_config 's/output_cost_per_token: .*/output_cost_per_token: 0.0000009/'
  run "$REPO/scripts/check-prices.sh" "$BATS_TEST_TMPDIR/config.yaml"
  echo "$output"
  [ "$status" -eq 1 ]
  grep -q "^rules ok: $(config_count) entries" <<<"$output"
  grep -q "^FAIL chat-tasks (deepinfra/fp8): price is now" <<<"$output"
}

@test "rules: max_tokens under model_info does not count" {
  # LiteLLM applies a default max_tokens only from litellm_params.
  broken_config '/max_tokens:/d; s/^\(      \)rapidselector_kind: role$/\1rapidselector_kind: role\n\1max_tokens: 1024/'
  grep -A3 'model_info:' "$BATS_TEST_TMPDIR/config.yaml" | head -4
  rules_fail "cannot read max_tokens"
}

# reorder_second <file>: the second entry (gpt-oss-120b@coreweave) written with litellm_params
# first, model_name last (the same YAML).
reorder_second() {
  awk '/^  - model_name: gpt-oss-120b@coreweave$/ { pending = 1; next }
    pending && /^    litellm_params:$/ { print "  - litellm_params:"; next }
    pending && /^    model_info:$/ { print "    model_name: gpt-oss-120b@coreweave"; pending = 0 }
    { print }' "$RAPIDSELECTOR_GATEWAY_CONFIG" > "$1"
}

@test "rules: an entry with its keys in another order is read as its own entry" {
  reorder_second "$BATS_TEST_TMPDIR/config.yaml"
  run "$REPO/scripts/check-prices.sh" --rules-only "$BATS_TEST_TMPDIR/config.yaml"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "^rules ok: $(config_count) entries" <<<"$output"
}

@test "rules: a broken entry before a reordered one still fails" {
  reorder_second "$BATS_TEST_TMPDIR/reordered.yaml"
  sed '0,/zdr: true/s//zdr: false/' "$BATS_TEST_TMPDIR/reordered.yaml" > "$BATS_TEST_TMPDIR/config.yaml"
  rules_fail "zdr must be true"
}

@test "rules: a field written twice in one entry fails closed" {
  broken_config 's/^\(          \)zdr: true$/\1zdr: true\n\1zdr: false/'
  rules_fail "cannot read zdr"
}

@test "rules: a comment after order is ignored" {
  broken_config 's@^\( *\)order: \["deepinfra/fp8"\]$@\1order: ["deepinfra/fp8"]  # pinned@'
  [ "$(grep -c '# pinned' "$BATS_TEST_TMPDIR/config.yaml")" = "1" ]
  run "$REPO/scripts/check-prices.sh" --rules-only "$BATS_TEST_TMPDIR/config.yaml"
  echo "$output"
  [ "$status" -eq 0 ]
  # The price part matches the same tag.
  run "$REPO/scripts/check-prices.sh" "$BATS_TEST_TMPDIR/config.yaml"
  echo "$output"
  [ "$status" -eq 0 ]
}

# broken_home <sed expression>: $BATS_TEST_TMPDIR/home.env is the example home.env with the
# expression applied, and RAPIDSELECTOR_HOME_ENV points at it.
broken_home() {
  sed -e "$1" "$RAPIDSELECTOR_HOME_ENV" > "$BATS_TEST_TMPDIR/home.env"
  ! cmp -s "$RAPIDSELECTOR_HOME_ENV" "$BATS_TEST_TMPDIR/home.env"
  export RAPIDSELECTOR_HOME_ENV="$BATS_TEST_TMPDIR/home.env"
}

# home_fails <text>: the rules check failed with the line "FAIL home.env: <text>".
home_fails() {
  run "$REPO/scripts/check-prices.sh" --rules-only "$RAPIDSELECTOR_GATEWAY_CONFIG"
  echo "$output"
  [ "$status" -eq 1 ]
  grep -qF "FAIL home.env: $1" <<<"$output"
  ! grep -q "^rules ok" <<<"$output"
}

@test "home.env: a missing name" {
  broken_home '/^NODE_RED_TPM=/d'
  home_fails "missing NODE_RED_TPM"
}

@test "home.env: the environment does not hide a missing name" {
  broken_home '/^NODE_RED_TPM=/d'
  export NODE_RED_TPM=5
  home_fails "missing NODE_RED_TPM"
}

@test "home.env: a budget of zero" {
  broken_home 's/^BUDGET_KEY_NODE_RED=.*/BUDGET_KEY_NODE_RED=0/'
  home_fails "BUDGET_KEY_NODE_RED must be a number above zero"
}

@test "home.env: a quoted budget" {
  broken_home 's/^BUDGET_TEAM_PERMANENT=.*/BUDGET_TEAM_PERMANENT="2"/'
  home_fails "BUDGET_TEAM_PERMANENT must be a number above zero"
}

@test "home.env: a limit with a comment after it" {
  broken_home 's/^NODE_RED_RPM=.*/NODE_RED_RPM=30 # per minute/'
  home_fails "NODE_RED_RPM must be a whole number above zero"
}

@test "home.env: a provider with an endpoint" {
  broken_home 's#^ALLOWED_HOSTS=.*#ALLOWED_HOSTS=deepinfra/fp8 coreweave#'
  home_fails "ALLOWED_HOSTS must be provider tags"
}

@test "home.env: team budgets above the global budget" {
  broken_home 's/^BUDGET_TEAM_EXPERIMENTS=.*/BUDGET_TEAM_EXPERIMENTS=8.5/'
  home_fails "team budgets add up to 10.5, above the global budget 10"
}

@test "home.env: no max_budget in gateway.yaml" {
  sed '/^  max_budget:/d' "$RAPIDSELECTOR_GATEWAY_CONFIG" > "$BATS_TEST_TMPDIR/config.yaml"
  run "$REPO/scripts/check-prices.sh" --rules-only "$BATS_TEST_TMPDIR/config.yaml"
  echo "$output"
  [ "$status" -eq 1 ]
  grep -qx "FAIL litellm_settings: cannot read max_budget" <<<"$output"
}

@test "home.env: not found" {
  RAPIDSELECTOR_HOME_ENV="$BATS_TEST_TMPDIR/none.env" run "$REPO/scripts/check-prices.sh" --rules-only
  echo "$output"
  [ "$status" -eq 2 ]
  grep -q "cannot read" <<<"$output"
}

@test "home.env: a setting written twice" {
  broken_home '$a BUDGET_TEAM_EXPERIMENTS=50'
  home_fails "BUDGET_TEAM_EXPERIMENTS is set more than once"
}

@test "home.env: a directory is not a file" {
  mkdir "$BATS_TEST_TMPDIR/home.env"
  RAPIDSELECTOR_HOME_ENV="$BATS_TEST_TMPDIR/home.env" run "$REPO/scripts/check-prices.sh" --rules-only
  echo "$output"
  [ "$status" -eq 2 ]
  [ "$output" = "cannot read $BATS_TEST_TMPDIR/home.env" ]
}
