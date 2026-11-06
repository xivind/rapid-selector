#!/usr/bin/env bats
# Level 1: tower against the full test stack, with the fake upstream standing in for
# OpenRouter's inference and management APIs. Nothing here reaches OpenRouter.

load helpers

TOWER_URL="http://127.0.0.1:4020"

setup_file() {
  stack_up
  run_setup_keys > "$ARTIFACTS/tower-setup-keys.txt"
}

teardown_file() {
  stack_down
}

setup() {
  upstream_reset
  upstream_mode 200
  openrouter_state '{}'
  tower_login
}

# tower_login: log in to tower; the session cookie goes to $BATS_TEST_TMPDIR/tower.jar.
tower_login() {
  curl -sS -o /dev/null -c "$BATS_TEST_TMPDIR/tower.jar" \
    --data-urlencode "password=$(test_env TOWER_PASSWORD)" "$TOWER_URL/login"
}

# tower_get <path>: the page as the logged-in owner. Sets $output and $TOWER_STATUS.
tower_get() {
  output="$(curl -sS -b "$BATS_TEST_TMPDIR/tower.jar" -w '\n%{http_code}' "$TOWER_URL$1")"
  TOWER_STATUS="${output##*$'\n'}"
  output="${output%$'\n'*}"
}

# tower_post <path> [name=value...]: a form post as the logged-in owner. Sets $output and $TOWER_STATUS.
tower_post() {
  local path="$1" args=() field
  shift
  for field in "$@"; do args+=(--data-urlencode "$field"); done
  [ "${#args[@]}" -gt 0 ] || args=(-d '')
  output="$(curl -sS -b "$BATS_TEST_TMPDIR/tower.jar" -w '\n%{http_code}' -X POST "${args[@]}" "$TOWER_URL$path")"
  TOWER_STATUS="${output##*$'\n'}"
  output="${output%$'\n'*}"
}

# tower_until <path> <text> [seconds]: wait until the page contains the text. Client reads are
# cached for 30 seconds, so a change at a source shows within about that.
tower_until() {
  local deadline=$((SECONDS + ${3:-40}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    tower_get "$1"
    [[ "$output" == *"$2"* ]] && return 0
    sleep 2
  done
  echo "$1 never showed: $2" >&2
  return 1
}

master() {
  test_env LITELLM_MASTER_KEY
}

# gw_admin <method> <path> [json]: a gateway management call with the master key.
gw_admin() {
  curl -sS -X "$1" -H "Authorization: Bearer $(master)" -H 'Content-Type: application/json' \
    ${3:+-d "$3"} "$GATEWAY_URL$2"
}

key_blocked() {
  key_info "$1" | jq -r '.info.blocked == true'
}

# The fake inference key as OpenRouter's management API reports it.
or_key() {
  curl -sS -H "Authorization: Bearer $(test_env OPENROUTER_MANAGEMENT_KEY)" \
    "$FAKE_UPSTREAM_URL/api/v1/keys?include_disabled=true" | jq -c '.data[0]'
}

engage() {
  tower_post "/kill/engage/$1" confirm=yes
  [ "$TOWER_STATUS" = "200" ] || { echo "engage $1: HTTP $TOWER_STATUS"; return 1; }
}

release() {
  tower_post "/kill/release/$1" word=release
  [ "$TOWER_STATUS" = "200" ] || { echo "release $1: HTTP $TOWER_STATUS"; return 1; }
}

@test "tower is healthy and needs a login" {
  run curl -sS -o /dev/null -w '%{http_code}' "$TOWER_URL/health"
  [ "$output" = "200" ]
  run curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "$TOWER_URL/"
  [ "$output" = "303 $TOWER_URL/login" ]
  for path in /usage /setup /log /partials/killswitch; do
    run curl -sS -o /dev/null -w '%{http_code}' "$TOWER_URL$path"
    [ "$output" = "303" ] || { echo "$path: $output"; false; }
  done
  run curl -sS -o /dev/null -w '%{http_code}' -X POST -d confirm=yes "$TOWER_URL/kill/engage/1"
  [ "$output" = "401" ]
  run curl -sS -d password=wrong "$TOWER_URL/login"
  [[ "$output" == *"Wrong password."* ]]
  tower_get /
  [ "$TOWER_STATUS" = "200" ]
  tower_get /partials/killswitch
  [[ "$output" == *"ALL CLEAR"* ]]
}

@test "level 1 blocks node-red and chat but not tower" {
  # Refusals change nothing and answer 200, with the reason in the partial.
  tower_post /kill/engage/1
  [ "$TOWER_STATUS" = "200" ]
  [[ "$output" == *"Nothing changed: confirm first."* ]]
  [ "$(key_blocked "$(test_env KEY_CHAT)")" = "false" ]

  engage 1
  [[ "$output" == *"LEVEL 1"* ]]
  gw_call "$(test_env KEY_NODE_RED)" classify
  [ "$GW_STATUS" = "401" ]
  gw_call "$(test_env KEY_CHAT)" chat
  [ "$GW_STATUS" = "401" ]
  [ "$(key_blocked "$(test_env TOWER_GATEWAY_KEY)")" = "false" ]
  for path in / /usage /setup /log /partials/killswitch; do
    tower_get "$path"
    [ "$TOWER_STATUS" = "200" ] || { echo "$path: $TOWER_STATUS"; false; }
  done

  tower_post /kill/release/1 word=releas
  [ "$TOWER_STATUS" = "200" ]
  [[ "$output" == *'Nothing changed: type the word &#34;release&#34;.'* || "$output" == *'Nothing changed: type the word "release".'* ]]
  [ "$(key_blocked "$(test_env KEY_CHAT)")" = "true" ]

  release 1
  [[ "$output" == *"ALL CLEAR"* ]]
  gw_call "$(test_env KEY_NODE_RED)" classify
  [ "$GW_STATUS" = "200" ]
}

@test "a key created while level 1 is engaged is blocked within 70 seconds" {
  engage 1
  late="sk-test-$(openssl rand -hex 16)"
  gw_admin POST /key/generate "$(jq -nc --arg k "$late" '{key:$k, key_alias:"late-key", team_id:"experiments"}')" >/dev/null
  deadline=$((SECONDS + 70))
  until [ "$(key_blocked "$late")" = "true" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "late-key not blocked after 70 s"; false; }
    sleep 5
  done
  gw_call "$late" classify
  [ "$GW_STATUS" = "401" ]
  release 1
  [ "$(key_blocked "$late")" = "false" ]
  gw_admin POST /key/delete "$(jq -nc --arg k "$late" '{keys:[$k]}')" >/dev/null
}

@test "LiteLLM's admin UI while level 1 is engaged" {
  # Records what the UI's login creates and whether tower's loop blocks it; the owner decides
  # what level 1 should do about it. The test fails only if the UI stops working.
  engage 1
  jar="$BATS_TEST_TMPDIR/ui.jar"
  run curl -sS -c "$jar" -o /dev/null -w '%{http_code}' -X POST \
    --data-urlencode username=admin --data-urlencode "password=$(test_env LITELLM_UI_PASSWORD)" "$GATEWAY_URL/login"
  [ "$output" = "303" ]
  session="$(awk '$6 == "token" { print $7 }' "$jar" | cut -d. -f2 | tr '_-' '/+')"
  session="$session$(printf '%*s' $(( (4 - ${#session} % 4) % 4 )) '' | tr ' ' '=')"
  ui_key="$(base64 -d <<<"$session" | jq -r '.key')"
  [ -n "$ui_key" ] && [ "$ui_key" != "null" ]
  sleep 70
  info="$(key_info "$ui_key" | jq -c '.info | {key_alias, user_id, team_id, blocked, max_budget, expires, models}')"
  listed="$(curl -sS -G -H "Authorization: Bearer $(test_env TOWER_GATEWAY_KEY)" --data-urlencode return_full_object=true \
    "$GATEWAY_URL/key/list" | jq --arg t "$(printf '%s' "$ui_key" | sha256sum | cut -d' ' -f1)" '[.keys[] | select(.token == $t)] | length')"
  gw_call "$ui_key" classify
  {
    echo "UI session key after 70 s at level 1: $info"
    echo "in tower's /key/list: $listed; model call with it: HTTP $GW_STATUS"
  } | tee "$ARTIFACTS/ui-session-key.txt" >&3
  for path in /ui/ /model/info /key/list "/user/info?user_id=$(jq -r '.user_id' <<<"$info")"; do
    run curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ui_key" "$GATEWAY_URL$path"
    [ "$output" = "200" ] || { echo "UI call $path: $output"; false; }
  done
  release 1
}

@test "releasing level 1 unblocks only what tower blocked" {
  gw_admin POST /key/block "$(jq -nc --arg k "$(test_env KEY_CHAT)" '{key:$k}')" >/dev/null
  engage 1
  [[ "$output" == *"Blocked outside tower: chat."* ]]
  release 1
  [ "$(key_blocked "$(test_env KEY_CHAT)")" = "true" ]
  [ "$(key_blocked "$(test_env KEY_NODE_RED)")" = "false" ]
  [[ "$output" == *"Blocked outside tower: chat."* ]]
  gw_admin POST /key/unblock "$(jq -nc --arg k "$(test_env KEY_CHAT)" '{key:$k}')" >/dev/null
  tower_until /partials/killswitch "ALL CLEAR"
}

@test "level 2 disables the key at the fake and chat calls fail" {
  engage 2
  [[ "$output" == *"LEVEL 2"* ]]
  [ "$(or_key | jq -r '.disabled')" = "true" ]
  # The master key is not blocked by level 1, so this call reaches the upstream and gets its 401.
  gw_call "$(master)" classify
  [ "$GW_STATUS" != "200" ]
  [ "$(upstream_requests | jq 'length')" -ge 1 ]
  gw_call "$(test_env KEY_CHAT)" chat
  [ "$GW_STATUS" = "401" ]
  release 2
  release 1
  [[ "$output" == *"ALL CLEAR"* ]]
}

@test "release level 2 leaves level 1 engaged" {
  engage 2
  [ "$(or_key | jq -r '.disabled')" = "true" ]
  tower_post /kill/release/1 word=release
  [[ "$output" == *"release level 2 first"* ]]
  release 2
  [ "$(or_key | jq -r '.disabled')" = "false" ]
  [[ "$output" == *"LEVEL 1"* ]]
  gw_call "$(test_env KEY_NODE_RED)" classify
  [ "$GW_STATUS" = "401" ]
  # The 401s while the key was disabled put the model group in LiteLLM's cooldown (about 5 s).
  deadline=$((SECONDS + 30))
  until gw_call "$(master)" classify && [ "$GW_STATUS" = "200" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "master key call: $GW_STATUS $output"; false; }
    sleep 2
  done
  release 1
  [[ "$output" == *"ALL CLEAR"* ]]
}

@test "a failed read-back shows the state as unknown" {
  openrouter_state '{"fail":"keys"}'
  tower_until /partials/killswitch "STATE UNKNOWN"
  [[ "$output" == *"openrouter unavailable: HTTP 500"* ]]
  for path in / /usage /setup /log; do
    tower_get "$path"
    [ "$TOWER_STATUS" = "200" ] || { echo "$path: $TOWER_STATUS"; false; }
  done
  openrouter_state '{}'
  tower_until /partials/killswitch "ALL CLEAR"
}

@test "the price check passes against the fake list and fails after a price change" {
  tower_post /checks/price
  [ "$TOWER_STATUS" = "200" ]
  [[ "$output" == *"price-results"* ]]
  [[ "$output" != *"FAIL:"* ]] || { echo "$output"; false; }
  zdr="$(curl -sS "$FAKE_UPSTREAM_URL/api/v1/endpoints/zdr" | jq -c '.data | .[0].pricing.prompt = "0.001"')"
  openrouter_state "$(jq -nc --argjson z "$zdr" '{zdr:$z}')"
  sleep 31  # tower caches the list for 30 seconds
  tower_post /checks/price
  [[ "$output" == *"FAIL: price is now 0.001"* ]] || { echo "$output"; false; }
  [ "$(grep -c 'FAIL:' <<<"$output")" = "1" ]
}

@test "reconciliation is flagged when the fake's usage differs by more than the threshold" {
  openrouter_state '{"keys":[{"hash":"recon","name":"rapidselector-gateway","label":"sk-or-v1-0e6...1c96","disabled":false,"limit":20,"limit_remaining":15,"limit_reset":"monthly","usage":5,"usage_daily":0,"usage_weekly":0,"usage_monthly":5,"expires_at":null}]}'
  tower_until / "gap above \$0.05 or 5%"
  openrouter_state '{}'
  sleep 31
  tower_get /
  [[ "$output" == *"RECONCILIATION, THIS MONTH"* ]]
  [[ "$output" != *"gap above \$0.05 or 5%"* ]]
}

@test "metrics report the kill switch level" {
  run curl -sS "$TOWER_URL/metrics"
  [[ "$output" == *"rapidselector_kill_switch_level"* ]]
  engage 1
  deadline=$((SECONDS + 70))
  until curl -sS "$TOWER_URL/metrics" | grep -qx 'rapidselector_kill_switch_level 1.0'; do
    [ "$SECONDS" -lt "$deadline" ] || { curl -sS "$TOWER_URL/metrics" | grep kill_switch; false; }
    sleep 5
  done
  release 1
}

@test "with the gateway down, pages render and level 2 still works" {
  docker stop rapidselector-gateway >/dev/null
  tower_until /partials/killswitch "STATE UNKNOWN"  # reads are cached for 30 seconds
  for path in / /usage /setup /log /partials/killswitch; do
    start=$SECONDS
    tower_get "$path"
    [ "$TOWER_STATUS" = "200" ] || { echo "$path: $TOWER_STATUS"; false; }
    [ $((SECONDS - start)) -le 7 ] || { echo "$path took $((SECONDS - start)) s"; false; }
  done
  [[ "$output" == *"gateway unavailable"* ]]
  engage 2
  [ "$(or_key | jq -r '.disabled')" = "true" ]
  release 2
  [ "$(or_key | jq -r '.disabled')" = "false" ]
  docker start rapidselector-gateway >/dev/null
  deadline=$((SECONDS + 180))
  until [ "$(docker inspect -f '{{.State.Health.Status}}' rapidselector-gateway)" = "healthy" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { echo "gateway not healthy again"; false; }
    sleep 3
  done
  # Level 2 engaged level 1 too: once the gateway is back, tower blocks the keys it could not
  # reach, and releasing level 2 never went from everything stopped to everything running.
  tower_until /partials/killswitch "LEVEL 1</strong>" 100  # complete, not "LEVEL 1 · PARTIAL"
  [ "$(key_blocked "$(test_env KEY_CHAT)")" = "true" ]
  [ "$(key_blocked "$(test_env KEY_NODE_RED)")" = "true" ]
  release 1
  [[ "$output" == *"ALL CLEAR"* ]] || { echo "$output"; false; }
  [ "$(key_blocked "$(test_env KEY_CHAT)")" = "false" ]
}

@test "no secret value in any page, /metrics or tower's container log" {
  pages="$BATS_TEST_TMPDIR/pages.txt"
  : > "$pages"
  for path in / "/?period=day" "/?period=week" /usage /setup /log /partials/killswitch "/partials/killswitch?confirm=2" \
              /partials/checks "/checks/smoke?scope=all"; do
    tower_get "$path"
    printf '%s\n' "$output" >> "$pages"
  done
  curl -sS "$TOWER_URL/metrics" >> "$pages"
  curl -sS "$TOWER_URL/login" >> "$pages"
  docker logs rapidselector-tower >> "$pages" 2>&1
  for name in "${RAPIDSELECTOR_SECRETS[@]}"; do
    value="$(test_env "$name")"
    [ -n "$value" ] || continue
    if grep -qF -- "$value" "$pages"; then
      echo "the value of $name appears in a page, /metrics or the log"
      false
    fi
  done
}

@test "backup command gives a valid database" {
  docker exec rapidselector-tower python -m tower.backup > "$BATS_TEST_TMPDIR/tower.db"
  [ -s "$BATS_TEST_TMPDIR/tower.db" ]
  run python3 -c 'import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
print(db.execute("PRAGMA integrity_check").fetchone()[0])
print(db.execute("SELECT count(*) FROM sqlite_master WHERE type = \"table\"").fetchone()[0])' "$BATS_TEST_TMPDIR/tower.db"
  [ "${lines[0]}" = "ok" ]
  [ "${lines[1]}" -ge 1 ]
}
