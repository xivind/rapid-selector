#!/usr/bin/env bats
# Level 1: the two checkers, tested without the network: check-prices.sh against a saved
# endpoint list, check-arm64.sh with a stand-in docker. The live checks are run by hand
# (README, "For developers"), because Docker Hub's rate limit and hosts' price changes
# must not break the regression suite.

load helpers

setup() {
  # An endpoint list that matches gateway/config.yaml exactly, built from the config itself.
  awk '
    /^[[:space:]]*- model_name:/ { if (m != "") print m, i, o, s; m = i = o = s = "" }
    /^[[:space:]]*model: openrouter\// { m = substr($2, 12) }
    /^[[:space:]]*input_cost_per_token:/ { i = $2 }
    /^[[:space:]]*output_cost_per_token:/ { o = $2 }
    /^[[:space:]]*order:/ { s = $2; gsub(/[\[\]"]/, "", s) }
    END { print m, i, o, s }
  ' "$REPO/gateway/config.yaml" \
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
  [ "$(grep -c '^ok ' <<<"$output")" = "11" ]
}

@test "check-prices fails when a configured price differs" {
  sed 's/output_cost_per_token: 0.0000002$/output_cost_per_token: 0.0000009/' "$REPO/gateway/config.yaml" > "$BATS_TEST_TMPDIR/config.yaml"
  run "$REPO/scripts/check-prices.sh" "$BATS_TEST_TMPDIR/config.yaml"
  [ "$status" -eq 1 ]
  grep -q "^FAIL classify" <<<"$output"
}

@test "check-prices fails when a pinned endpoint does not exist" {
  sed 's/order: \["cloudflare"\]/order: ["nowhere\/fp8"]/' "$REPO/gateway/config.yaml" > "$BATS_TEST_TMPDIR/config.yaml"
  run "$REPO/scripts/check-prices.sh" "$BATS_TEST_TMPDIR/config.yaml"
  [ "$status" -eq 1 ]
  grep -q "^FAIL llama-3.2-1b-instruct@cloudflare" <<<"$output"
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
