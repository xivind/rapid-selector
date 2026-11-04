#!/usr/bin/env bats
# Level 1: the two checks that need no stack: arm64 images and allowlist prices.
# Both read public registries and OpenRouter's public API; they cost nothing.

load helpers

@test "check-arm64 passes for the pinned images" {
  run "$REPO/tests/check-arm64.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  for image in postgres:17.11-alpine ghcr.io/berriai/litellm-database:v1.106.6 ghcr.io/open-webui/open-webui:v0.13.0 python:3.15.2-alpine3.24; do
    grep -q "ok $image" <<<"$output" || { echo "no line for $image"; false; }
  done
}

@test "check-arm64 fails for an image without arm64" {
  printf 'services:\n  x:\n    image: ghcr.io/does-not-exist/nothing:0.0.0\n' > "$BATS_TEST_TMPDIR/compose.yml"
  run "$REPO/tests/check-arm64.sh" "$BATS_TEST_TMPDIR/compose.yml"
  [ "$status" -eq 1 ]
  grep -q "ghcr.io/does-not-exist/nothing:0.0.0" <<<"$output"
}

@test "check-prices passes for the allowlist" {
  run "$REPO/tests/check-prices.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ok ' <<<"$output")" = "11" ]
}

@test "check-prices fails when a configured price differs" {
  sed 's/output_cost_per_token: 0.0000002$/output_cost_per_token: 0.0000009/' "$REPO/gateway/config.yaml" > "$BATS_TEST_TMPDIR/config.yaml"
  run "$REPO/tests/check-prices.sh" "$BATS_TEST_TMPDIR/config.yaml"
  [ "$status" -eq 1 ]
  grep -q "classify" <<<"$output"
}

@test "check-prices fails when a pinned endpoint does not exist" {
  sed 's/order: \["cloudflare"\]/order: ["nowhere\/fp8"]/; s/only: \["cloudflare"\]/only: ["nowhere\/fp8"]/' "$REPO/gateway/config.yaml" > "$BATS_TEST_TMPDIR/config.yaml"
  run "$REPO/tests/check-prices.sh" "$BATS_TEST_TMPDIR/config.yaml"
  [ "$status" -eq 1 ]
  grep -q "llama-3.2-1b-instruct@cloudflare" <<<"$output"
}
