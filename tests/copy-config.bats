#!/usr/bin/env bats
# scripts/copy-config.sh against a stand-in ssh that serves a fake host folder (no network,
# no Docker).

load helpers

setup() {
  export FAKE_REMOTE="$BATS_TEST_TMPDIR/remote"
  export SSH_LOG="$BATS_TEST_TMPDIR/ssh.log"
  mkdir -p "$FAKE_REMOTE/code/rapid-selector" "$BATS_TEST_TMPDIR/local" "$BATS_TEST_TMPDIR/bin"
  echo "SECRET=x" > "$FAKE_REMOTE/code/rapid-selector/.env"
  cp "$RAPIDSELECTOR_GATEWAY_CONFIG" "$BATS_TEST_TMPDIR/local/gateway.yaml"
  cp "$RAPIDSELECTOR_HOME_ENV" "$BATS_TEST_TMPDIR/local/home.env"
  export RAPIDSELECTOR_GATEWAY_CONFIG="$BATS_TEST_TMPDIR/local/gateway.yaml"
  export RAPIDSELECTOR_HOME_ENV="$BATS_TEST_TMPDIR/local/home.env"
  export RAPIDSELECTOR_REMOTE_DIR=code/rapid-selector
  # A stand-in ssh: logs its arguments and runs the command in the fake host's home folder.
  # Like the real one, it reads what is left on stdin unless given -n.
  cat > "$BATS_TEST_TMPDIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$SSH_LOG"
no_stdin=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -n) no_stdin=1; shift ;;
    -o) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
shift # the host
cd "$FAKE_REMOTE" || exit 255
if [ "$no_stdin" -eq 1 ]; then
  bash -c "$*" </dev/null
  exit $?
fi
bash -c "$*"
rc=$?
cat >/dev/null
exit $rc
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/ssh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

remote_config() {
  echo "$FAKE_REMOTE/code/rapid-selector/config"
}

# remote_files: put the local files on the fake host, the gateway config with one line changed.
remote_files() {
  mkdir -p "$(remote_config)"
  sed 's/^  max_budget: 10$/  max_budget: 11/' "$RAPIDSELECTOR_GATEWAY_CONFIG" > "$(remote_config)/gateway.yaml"
  cp "$RAPIDSELECTOR_HOME_ENV" "$(remote_config)/home.env"
}

@test "to copies both files and prints the next steps" {
  run "$REPO/scripts/copy-config.sh" to pi@sandbox
  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$RAPIDSELECTOR_GATEWAY_CONFIG" "$(remote_config)/gateway.yaml"
  cmp "$RAPIDSELECTOR_HOME_ENV" "$(remote_config)/home.env"
  [[ "$output" == *"./rapidselector.sh restart gateway"* ]]
  [[ "$output" == *"setup-keys.sh"* ]]
  [ "$(wc -l < "$SSH_LOG")" -eq 1 ]
}

@test "to refuses a broken rule and sends nothing" {
  sed -i 's/^BUDGET_TEAM_EXPERIMENTS=.*/BUDGET_TEAM_EXPERIMENTS=99/' "$RAPIDSELECTOR_HOME_ENV"
  run "$REPO/scripts/copy-config.sh" to pi@sandbox
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL home.env: team budgets"* ]]
  [ ! -e "$SSH_LOG" ]
  [ ! -e "$(remote_config)" ]
}

@test "to a host without the clone exits 2 and creates nothing" {
  RAPIDSELECTOR_REMOTE_DIR=code/elsewhere run "$REPO/scripts/copy-config.sh" to pi@sandbox
  echo "$output"
  [ "$status" -eq 2 ]
  [ ! -e "$FAKE_REMOTE/code/elsewhere" ]
}

@test "to without local home.env exits 2" {
  rm "$RAPIDSELECTOR_HOME_ENV"
  run "$REPO/scripts/copy-config.sh" to pi@sandbox
  [ "$status" -eq 2 ]
  [ ! -e "$SSH_LOG" ]
}

@test "from writes the files when there are none locally" {
  remote_files
  rm "$RAPIDSELECTOR_GATEWAY_CONFIG" "$RAPIDSELECTOR_HOME_ENV"
  run "$REPO/scripts/copy-config.sh" from pi@sandbox </dev/null
  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$(remote_config)/gateway.yaml" "$RAPIDSELECTOR_GATEWAY_CONFIG"
  cmp "$(remote_config)/home.env" "$RAPIDSELECTOR_HOME_ENV"
}

@test "from asks before overwriting, and no keeps them" {
  remote_files
  cp "$RAPIDSELECTOR_GATEWAY_CONFIG" "$BATS_TEST_TMPDIR/before.yaml"
  run "$REPO/scripts/copy-config.sh" from pi@sandbox < <(printf 'n\n')
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Overwrite"* ]]
  cmp "$BATS_TEST_TMPDIR/before.yaml" "$RAPIDSELECTOR_GATEWAY_CONFIG"
}

@test "from overwrites on y, after ssh has run" {
  remote_files
  run "$REPO/scripts/copy-config.sh" from pi@sandbox < <(printf 'y\n')
  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$(remote_config)/gateway.yaml" "$RAPIDSELECTOR_GATEWAY_CONFIG"
}

@test "from with files missing on the host exits 2" {
  run "$REPO/scripts/copy-config.sh" from pi@sandbox </dev/null
  echo "$output"
  [ "$status" -eq 2 ]
  [ -f "$RAPIDSELECTOR_GATEWAY_CONFIG" ]
}

@test "the host is asked for when not given" {
  run "$REPO/scripts/copy-config.sh" to < <(printf 'pi@sandbox\n')
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "pi@sandbox" "$SSH_LOG"
}

@test "the remote folder defaults to the clone's place under HOME" {
  unset RAPIDSELECTOR_REMOTE_DIR
  HOME="$(dirname "$(dirname "$REPO")")" run "$REPO/scripts/copy-config.sh" to pi@sandbox
  echo "$output"
  grep -qF "$(basename "$(dirname "$REPO")")/$(basename "$REPO")" "$SSH_LOG"
}

@test "the remote folder comes from home.env" {
  unset RAPIDSELECTOR_REMOTE_DIR
  echo "RAPIDSELECTOR_REMOTE_DIR=code/rapid-selector" >> "$RAPIDSELECTOR_HOME_ENV"
  run "$REPO/scripts/copy-config.sh" to pi@sandbox
  echo "$output"
  [ "$status" -eq 0 ]
  cmp "$RAPIDSELECTOR_HOME_ENV" "$(remote_config)/home.env"
}

@test ".env is never touched" {
  run "$REPO/scripts/copy-config.sh" to pi@sandbox
  [ "$status" -eq 0 ]
  run "$REPO/scripts/copy-config.sh" from pi@sandbox </dev/null
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_REMOTE/code/rapid-selector/.env")" = "SECRET=x" ]
  ! grep -E '(^|[^a-z])\.env' "$SSH_LOG"
}

@test "wrong usage exits 2" {
  run "$REPO/scripts/copy-config.sh" sideways pi@sandbox
  [ "$status" -eq 2 ]
  [ ! -e "$SSH_LOG" ]
}
