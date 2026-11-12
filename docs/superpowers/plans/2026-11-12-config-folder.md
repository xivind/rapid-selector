# A `config/` folder for each home's own settings: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every home-specific setting into `config/` (git-ignored `gateway.yaml` and `home.env`, with committed examples), check `home.env` with the rules check, add the role `chat-tasks` for Open WebUI's background calls, and add `scripts/copy-config.sh` to copy a home's files to or from the host over SSH.

**Architecture:** Fixed paths `config/gateway.yaml` and `config/home.env`, each with a test-only override variable (`RAPIDSELECTOR_GATEWAY_CONFIG`, which exists today, and `RAPIDSELECTOR_HOME_ENV`). Compose mounts `${RAPIDSELECTOR_GATEWAY_CONFIG:-./config/gateway.yaml}`, so the file the rules check reads is always the file the gateway mounts. `tests/helpers.bash` points both variables at the example files, so every suite tests the examples. The `home.env` names and its rules live in `scripts/lib.sh` beside the secret names. `check-prices.sh` reads `ALLOWED_HOSTS` from `home.env` and checks `home.env` as part of its rules.

**Tech stack:** bash, `jq` (must work with jq 1.6), `awk`, `ssh` and `tar` (no `rsync` or `scp`), bats 1.11.0, Docker Compose for level 1, LiteLLM v1.106.6, Open WebUI v0.13.0-slim.

**Spec:** `docs/superpowers/specs/2026-11-11-config-folder-design.md`. Read it first; this plan argues from it.

## Global constraints

- **Branch `config-folder` from `main`, built in the worktree `.worktrees/config-folder`.** Records (`docs/decisions.md`, `docs/test-procedures/phase-0-status.md`) are committed on `main` in the main checkout, as now.
- **The owner's own files (Task 8) are written in the main checkout's `config/`** (`/home/xivind/code/rapid-selector/config/`), never in the worktree: they are git-ignored, so the worktree's copies vanish when it is removed. Git-ignored files are not touched when branches change, so they wait there for the merge.
- One rule: **`scripts/` is what runs, the same for everyone; `config/` is what is yours.** `.env` stays where it is and is never copied or read by `copy-config.sh`.
- No secret in `config/`. `home.env` holds budgets, limits, provider tags and an optional folder, nothing else.
- **A missing `config/` file is an error, never a fallback to an example.** No script reads an example file unless it is told to by a variable or an argument.
- `home.env` is read only by `load_env_file` in `lib.sh` (literal `KEY=VALUE`, no shell evaluation). A variable already in the environment wins, which keeps today's `BUDGET_*` test overrides working.
- Exit codes: routine scripts `0` / `1` / `2` as now; `lib.sh` `2` (file not found), `3` (a missing value), `4`; `rapidselector.sh` `5` (a rule is broken, not restarted); `copy-config.sh` `0` done, `1` refused (a rule broken, or the answer was no), `2` could not run.
- Every new script starts with the usual header: what and why, how to run, secrets, cost, exit codes.
- The owner types short commands only. `copy-config.sh` asks `ssh` for the password once per run, and never sees it.
- **Where tests run:** this machine has no Docker. Run here what needs no Docker: `tests/checks.bats`, `tests/copy-config.bats`, `tests/ops-logic.bats`, `tests/smoke-args.bats`, and `tests/rapidselector.bats` with the fakes as in `docs/test-procedures/phase-0-status.md`, "For developers on this machine". Every bats file that needs Docker is changed test-first in its task and run in the cloud Docker run (Task 9). Until then, a task's report says "not yet verified in Docker".
- Example values (used by the tests; change them only in Task 1, together with every test that uses them):
  - `config/gateway.example.yaml`: three entries, in this order: `chat-tasks` (role; `meta-llama/llama-3.1-8b-instruct`, `deepinfra/fp8`, input 0.00000002, output 0.00000004, `max_tokens` 2048, `reasoning: false`); `gpt-oss-120b@coreweave` (experiment; `openai/gpt-oss-120b`, `coreweave/fp4`, 0.00000003, 0.00000017, 8192, `reasoning: true`); `qwen3.8-2.4t-a95b@siliconflow` (experiment; `qwen/qwen3.8-2.4t-a95b`, `siliconflow/fp8`, 0.000002, 0.000006, 8192, `reasoning_effort: medium`, `reasoning: true`). `litellm_settings.max_budget: 10`. Everything else is as in today's `gateway/config.yaml`.
  - `config/home.example.env`: `BUDGET_TEAM_PERMANENT=2`, `BUDGET_TEAM_EXPERIMENTS=8`, `BUDGET_KEY_NODE_RED=1`, `BUDGET_KEY_SMOKE_TEST=1`, `NODE_RED_RPM=30`, `NODE_RED_TPM=100000`, `ALLOWED_HOSTS=coreweave deepinfra siliconflow`, and `# RAPIDSELECTOR_REMOTE_DIR=code/rapid-selector` commented out.
  - Why these: `chat-tasks` must exist in every home's config, because Compose names it. The example has only one role, so `chat-tasks` is that role. `qwen3.8` keeps `tests/drain.bats` and the `reasoning_effort` test unchanged. There are three hosts. The team budgets add up to exactly the global budget, so the example also proves that equal is allowed.
- The owner's values (Task 8): exactly today's. Budgets 8 / 24 / 4 / 1, `NODE_RED_RPM=30`, `NODE_RED_TPM=100000`, `ALLOWED_HOSTS=cloudflare coreweave deepinfra siliconflow`, `max_budget: 32`, and the 11 entries unchanged, plus `chat-tasks`.

## Review focus

1. **A variable in the environment hides a name missing from `home.env`.** `load_env_file` lets the environment win, so a stray exported `NODE_RED_TPM` would make the check pass on a file that lacks it, and the next shell would fail. The check must judge the file alone. Test in Task 2.
2. **`config/gateway.yaml` is a directory**, left by Docker after an earlier `up` without the file. `rapidselector.sh` must refuse it as "not found", not pass a directory to Compose. Test in Task 3.
3. **`from` asks y/N after `ssh` has run.** Real `ssh` reads standard input, so the owner's answer (or a test's piped `y`) would be swallowed unless `ssh -n` is used for `from`. Test in Task 6, where the stand-in `ssh` drains standard input when it gets no `-n`.
4. **`to` a host with no clone at the remote folder** (wrong user, or not cloned yet) must exit 2 and create nothing there. A stray `~/code/rapid-selector/config/` would make a later `git clone` into that folder fail. Test in Task 6.
5. **A quoted or decorated value in `home.env`** (`BUDGET_TEAM_PERMANENT="8"`, or `30 # per minute`) is read literally, so it must be refused as not a number rather than sent to LiteLLM. Test in Task 2.

---

### Task 1: The example files, and the rules check and tests on them

**Files:**
- Create: `config/gateway.example.yaml`, `config/home.example.env`
- Modify: `.gitignore` (add `config/gateway.yaml` and `config/home.env`)
- Modify: `scripts/lib.sh` (add `RAPIDSELECTOR_HOME_SETTINGS`, `set_config_paths`)
- Modify: `scripts/check-prices.sh` (default config path; `ALLOWED_HOSTS` from `home.env`; header)
- Modify: `tests/helpers.bash`, `tests/checks.bats`, `tests/fakes.bats`, `tests/compose.fakes.yml`

**Interfaces:**
- Produces in `lib.sh`:
  - `RAPIDSELECTOR_HOME_SETTINGS=(BUDGET_TEAM_PERMANENT BUDGET_TEAM_EXPERIMENTS BUDGET_KEY_NODE_RED BUDGET_KEY_SMOKE_TEST NODE_RED_RPM NODE_RED_TPM ALLOWED_HOSTS)`: the only list of the names `home.env` must hold.
  - `set_config_paths <repo root>`: sets `GATEWAY_CONFIG="${RAPIDSELECTOR_GATEWAY_CONFIG:-<root>/config/gateway.yaml}"` and `HOME_ENV="${RAPIDSELECTOR_HOME_ENV:-<root>/config/home.env}"`.
  - `home_env_value <file> <NAME>`: prints NAME's value from the file alone (empty if absent), read with `load_env_file` in a subshell where NAME is unset, so a value in the environment cannot change what is checked.
- Produces in `tests/helpers.bash`: `export RAPIDSELECTOR_GATEWAY_CONFIG="$REPO/config/gateway.example.yaml"` and `export RAPIDSELECTOR_HOME_ENV="$REPO/config/home.example.env"`, near the top. Also two helpers: `config_count` prints the number of entries in `$RAPIDSELECTOR_GATEWAY_CONFIG` (lines matching `^  - model_name:`), and `config_roles` prints the names of the entries with `rapidselector_kind: role`, one per line.
- `check-prices.sh [--rules-only] [config file]`: the default config is `$GATEWAY_CONFIG`; it reads `home.env` from `$HOME_ENV`. If that file cannot be read, it prints `cannot read <path>` and exits 2.

- [ ] **Step 1:** Create the worktree and branch: `git worktree add .worktrees/config-folder -b config-folder main`. Work there from now on.
- [ ] **Step 2:** Write `config/gateway.example.yaml` from today's `gateway/config.yaml`. Copy the three entry blocks named in Global constraints: `llama-3.1-8b-instruct@deepinfra` becomes `chat-tasks` under a `# --- Roles ---` heading, with `rapidselector_kind: role`, and the other two go under `# --- Experiment names ---`. Set `max_budget: 10`, and keep `litellm_settings` and `general_settings` otherwise unchanged. The header comment says it is an example to copy to `config/gateway.yaml`, that `chat-tasks` must exist in every home (Open WebUI's titles; point it at your cheapest model), and that the prices were checked with `scripts/check-prices.sh` on the date of Step 9. Write `config/home.example.env` with the values in Global constraints, one comment line per setting saying what it is and which script reads it. The `ALLOWED_HOSTS` comment says it must match the allowed providers in the OpenRouter account. The budget comment says the team budgets must add up to no more than `max_budget` in `gateway.yaml`. Add the two ignored paths to `.gitignore`.
- [ ] **Step 3: Change the tests to the example first.** In `tests/helpers.bash`, add the exports and helpers above. In `tests/checks.bats`:
  - Replace every `"$REPO/gateway/config.yaml"` with `"$RAPIDSELECTOR_GATEWAY_CONFIG"`.
  - `grep -c '^ok '` and every `rules ok: 11 entries` compare against `$(config_count)` (3).
  - "configured price differs": sed `s/output_cost_per_token: 0.00000004$/output_cost_per_token: 0.0000009/`, then expect `^FAIL chat-tasks`.
  - "pinned endpoint does not exist": sed `s#order: \["coreweave/fp4"\]#order: ["nowhere/fp8"]#`, then expect `^FAIL gpt-oss-120b@coreweave`.
  - `rules_fail` and "prices still checked" expect `^FAIL chat-tasks` (`chat-tasks (deepinfra/fp8): price is now`).
  - `reorder_summarise` becomes `reorder_second`, which acts on `gpt-oss-120b@coreweave`.
  - Rename "rules: the real config passes" to "rules: the example passes".

  In `tests/fakes.bats`, "fake openrouter zdr list matches the config" reads `$RAPIDSELECTOR_GATEWAY_CONFIG`. In `tests/compose.fakes.yml`, the fake upstream mounts `./config/gateway.example.yaml:/config/config.yaml:ro`.
- [ ] **Step 4:** Run `npx --yes bats@1.11.0 tests/checks.bats`. Expected: FAIL. `check-prices.sh` still defaults to `gateway/config.yaml` (11 entries), and `ALLOWED_HOSTS` is still in the script.
- [ ] **Step 5:** Implement the `lib.sh` additions. In `check-prices.sh`: source `lib.sh`, call `set_config_paths "$repo"`, take `config="${1:-$GATEWAY_CONFIG}"`, refuse an unreadable `$HOME_ENV` (exit 2), and set `ALLOWED_HOSTS="$(home_env_value "$HOME_ENV" ALLOWED_HOSTS)"` in place of the hard-coded list. Update the header: the default config is `config/gateway.yaml`, and the allowed providers are `ALLOWED_HOSTS` in `config/home.env`.
- [ ] **Step 6:** Run `npx --yes bats@1.11.0 tests/checks.bats`. Expected: all pass.
- [ ] **Step 7:** Run `bash -n scripts/lib.sh scripts/check-prices.sh` and `RAPIDSELECTOR_HOME_ENV=config/home.example.env scripts/check-prices.sh --rules-only config/gateway.example.yaml`. Expected: `rules ok: 3 entries`, exit 0.
- [ ] **Step 8:** Commit: `feat: config/ examples, and check-prices reads the allowed providers from home.env`.
- [ ] **Step 9: The online price check on the example.** Run `RAPIDSELECTOR_HOME_ENV=config/home.example.env scripts/check-prices.sh config/gateway.example.yaml`. This is OpenRouter's public list: no key, no cost. Expected: three `ok` lines, exit 0. If a price has changed, update it in the example and in the `ENTRIES` table of Task 5, and record the change in `docs/provider-facts.md` with today's date. Put the date in the example's header, and commit: `docs: the example's prices checked on <date>`.

### Task 2: Checking `home.env`

**Files:**
- Modify: `scripts/lib.sh` (add `home_env_failures`), `scripts/check-prices.sh` (read `max_budget`, call the check), `tests/checks.bats`

**Interfaces:**
- Consumes: `RAPIDSELECTOR_HOME_SETTINGS`, `set_config_paths` and `home_env_value` (Task 1).
- Produces: `home_env_failures <home.env file> <global budget, or ->`, which prints one reason per broken rule, nothing if all pass. It reads every value with `home_env_value`, so it judges the file alone. The reasons, exactly:
  - `missing <NAME>`, for a name absent or empty;
  - `<NAME> must be a number above zero`, for each `BUDGET_*` that fails `^[0-9]+([.][0-9]+)?$` or is 0;
  - `<NAME> must be a whole number above zero`, for `NODE_RED_RPM` and `NODE_RED_TPM` (`^[1-9][0-9]*$`);
  - `ALLOWED_HOSTS must be provider tags separated by spaces, such as: deepinfra siliconflow`, if any word fails `^[a-z0-9][a-z0-9-]*$`;
  - `team budgets add up to <sum>, above the global budget <global> (litellm_settings.max_budget)`, if `BUDGET_TEAM_PERMANENT + BUDGET_TEAM_EXPERIMENTS > global`, compared as numbers with `awk`. It is skipped when the global budget is `-` or a team budget is already reported.
- `check-prices.sh` reads `max_budget` directly under `litellm_settings:` (one value, a trailing comment ignored; found twice or not at all means `-`). It prints `FAIL litellm_settings: cannot read max_budget` for `-`, and `FAIL home.env: <reason>` for each reason. Any such line makes the run fail (exit 1). `rules ok: N entries` is printed only when nothing failed.

- [ ] **Step 1: Write the failing tests** in `tests/checks.bats`, with a helper `broken_home <sed expression>` that writes `$BATS_TEST_TMPDIR/home.env` from the example and exports `RAPIDSELECTOR_HOME_ENV` to it. Each test runs `check-prices.sh --rules-only`, expects exit 1, and greps for the exact line:
  - `home.env: a missing name`: `/^NODE_RED_TPM=/d` gives `FAIL home.env: missing NODE_RED_TPM`.
  - `home.env: the environment does not hide a missing name` (review focus 1): the same file, run with `NODE_RED_TPM=5` in the environment, still gives `missing NODE_RED_TPM`.
  - `home.env: a budget of zero`: `s/^BUDGET_KEY_NODE_RED=.*/BUDGET_KEY_NODE_RED=0/` gives `BUDGET_KEY_NODE_RED must be a number above zero`.
  - `home.env: a quoted budget` (review focus 5): `s/^BUDGET_TEAM_PERMANENT=.*/BUDGET_TEAM_PERMANENT="2"/` gives the same reason for `BUDGET_TEAM_PERMANENT`.
  - `home.env: a limit with a comment after it` (review focus 5): `s/^NODE_RED_RPM=.*/NODE_RED_RPM=30 # per minute/` gives `NODE_RED_RPM must be a whole number above zero`.
  - `home.env: a provider with an endpoint`: `s#^ALLOWED_HOSTS=.*#ALLOWED_HOSTS=deepinfra/fp8 coreweave#` gives `ALLOWED_HOSTS must be provider tags`.
  - `home.env: team budgets above the global budget`: `s/^BUDGET_TEAM_EXPERIMENTS=.*/BUDGET_TEAM_EXPERIMENTS=8.5/` gives `team budgets add up to 10.5, above the global budget 10`.
  - `home.env: no max_budget in gateway.yaml`: the example with `/^  max_budget:/d` gives `FAIL litellm_settings: cannot read max_budget`.
  - `home.env: not found` (exit 2): `RAPIDSELECTOR_HOME_ENV=$BATS_TEST_TMPDIR/none.env` gives `cannot read`.

  Team budgets equal to the global budget already pass, through "rules: the example passes" (2 + 8 = 10).
- [ ] **Step 2:** Run `npx --yes bats@1.11.0 tests/checks.bats`. Expected: the new tests FAIL (no `home.env` lines yet), and the rest pass.
- [ ] **Step 3:** Implement `home_env_failures` in `lib.sh` and the `max_budget` reading and the calls in `check-prices.sh`. Mention the `home.env` rules in its header.
- [ ] **Step 4:** Run `npx --yes bats@1.11.0 tests/checks.bats`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat: the rules check also checks config/home.env, including team budgets against the global budget`.

### Task 3: `rapidselector.sh`, Compose and the role `chat-tasks`

**Files:**
- Modify: `rapidselector.sh`, `docker-compose.yml`, `tests/rapidselector.bats`, `tests/chat.bats` (title test only), `tests/stack.bats` (line 50), `gateway/request_guard.py` (comment, line 7)
- Delete: `gateway/config.yaml` (`git rm`; the owner's copy is written in Task 8)

**Interfaces:**
- Consumes: `set_config_paths`; `check-prices.sh` exits 0 / 1 / 2 (Tasks 1 and 2).
- Produces: before any Compose command (everything except `run-script`), `rapidselector.sh` refuses with exit 2 when `[ -f "$GATEWAY_CONFIG" ]` or `[ -f "$HOME_ENV" ]` fails. The messages are exactly `<path> not found: copy config/gateway.example.yaml to config/gateway.yaml and edit it (see config/README.md)` and `<path> not found: copy config/home.example.env to config/home.env and edit it (see config/README.md)`. `restart` passes `"$GATEWAY_CONFIG"` to the rules check. A broken rule gives `gateway not restarted: config/gateway.yaml or config/home.env breaks a rule` (exit 5).
- Compose: the gateway mounts `${RAPIDSELECTOR_GATEWAY_CONFIG:-./config/gateway.yaml}:/app/config.yaml:ro`, with a comment that the variable is for tests only. Chat gets `TASK_MODEL_EXTERNAL: chat-tasks`.

- [ ] **Step 1: Write the failing tests** in `tests/rapidselector.bats` (the stand-in `docker` is already there):
  - `up without config/gateway.yaml exits 2 and names the example`: `RAPIDSELECTOR_GATEWAY_CONFIG=$BATS_TEST_TMPDIR/none.yaml`, then expect exit 2, `copy config/gateway.example.yaml` in the output, and `[ ! -e "$DOCKER_CALL_LOG" ]`.
  - The same for `home.env` (`copy config/home.example.env`).
  - `a directory named gateway.yaml is refused` (review focus 2): `mkdir "$BATS_TEST_TMPDIR/gateway.yaml"` and point the variable at it. Expect exit 2 and no Docker call.
  - `run-script runs without config files`: both variables point at missing files, and `run-script bash -c 'echo ran'` prints `ran`, exit 0.
  - `restart gateway with a broken home.env exits 5`: `RAPIDSELECTOR_HOME_ENV` points at a copy of the example with `BUDGET_TEAM_EXPERIMENTS=99`. Expect exit 5, a `FAIL home.env: team budgets` line, `breaks a rule`, and no Docker call.
  - Change the existing tests: `rules_env` seds `$RAPIDSELECTOR_GATEWAY_CONFIG`. `rules ok: 11 entries` becomes `rules ok: $(config_count) entries`. `FAIL classify:` becomes `FAIL chat-tasks:`. The message is `gateway not restarted: config/gateway.yaml or config/home.env breaks a rule`. "restart gateway with an unreadable config" becomes "restart gateway without the config exits 2": expect exit 2, `copy config/gateway.example.yaml`, and no Docker call.
  - `compose mounts the file the rules check reads` (needs the real `docker`, so it goes in `tests/stack.bats`): `docker compose --project-directory "$REPO" --env-file "$TEST_ENV_FILE" -f "$REPO/docker-compose.yml" config --format json` shows the gateway volume with target `/app/config.yaml` and source `/x/y.yaml` when `RAPIDSELECTOR_GATEWAY_CONFIG=/x/y.yaml`, and source `$REPO/config/gateway.yaml` when the variable is unset.

  In `tests/chat.bats`, "title generation uses llama-3.1-8b-instruct@deepinfra" becomes "title generation uses the role chat-tasks". It posts with `"model":"gpt-oss-120b@coreweave"` and expects upstream models `["meta-llama/llama-3.1-8b-instruct"]`, the model `chat-tasks` points at in the example. In `tests/stack.bats` line 50, grep `"$RAPIDSELECTOR_GATEWAY_CONFIG"` instead of `gateway/config.yaml`.
- [ ] **Step 2:** Run `tests/rapidselector.bats` locally (see Global constraints). Expected: the new tests FAIL.
- [ ] **Step 3:** Implement it in `rapidselector.sh` (header too: `restart gateway` checks `config/gateway.yaml` and `config/home.env`) and `docker-compose.yml`. Run `git rm gateway/config.yaml`. Update the comment in `request_guard.py` to `config/gateway.yaml`.
- [ ] **Step 4:** Run `tests/rapidselector.bats` locally. Expected: all pass. `tests/stack.bats` and `tests/chat.bats` wait for Task 9.
- [ ] **Step 5:** Commit: `feat: rapidselector.sh refuses without config/ files; the gateway mounts config/gateway.yaml; chat uses the role chat-tasks`.

### Task 4: `setup-keys.sh` reads `home.env`

**Files:**
- Modify: `scripts/lib.sh` (add `load_home_env`), `scripts/setup-keys.sh`, `tests/keys.bats`, `tests/rapidselector.bats`

**Interfaces:**
- Consumes: `RAPIDSELECTOR_HOME_SETTINGS`, `set_config_paths`; `config_roles`, `config_count` (Task 1).
- Produces: `load_home_env <file>`. It refuses a missing file with exit 2 and `<path> not found: copy config/home.example.env to config/home.env and edit it (see config/README.md)`, then runs `load_env_file`, then `require_env "${RAPIDSELECTOR_HOME_SETTINGS[@]}"` (exit 3). `setup-keys.sh` calls it right after its `require_env` line, before any gateway call. It keeps `BUDGET_DURATION`, `ALLOWED_ROUTES`, `SCRIPTS_ROLE` and `SCRIPTS_ROUTES` (they are the same in every home), and loses the six values that moved. Header: the budgets and Node-RED's limits come from `config/home.env`; a `BUDGET_*` in the environment wins (tests only); exit 2 means `config/home.env` was not found.
- A helper in `tests/helpers.bash`: `home_value <NAME>` prints the value from `$RAPIDSELECTOR_HOME_ENV`.

- [ ] **Step 1: Write the failing tests.** In `tests/rapidselector.bats`: `setup-keys refuses without home.env`. Point `RAPIDSELECTOR_HOME_ENV` at a missing file and run `run-script scripts/setup-keys.sh` with the usual env file. Expect exit 2, `copy config/home.example.env`, and no `curl` call to the gateway (a stand-in `curl` first on `PATH` leaves a mark if called). In `tests/keys.bats`:
  - Budgets and limits come from `home_value`: `.max_budget == $(home_value BUDGET_KEY_NODE_RED)`, and the same for the team budgets, the smoke-test budget, `rpm_limit` and `tpm_limit`.
  - `experiments | .models | length` equals `$(config_count)`.
  - `permanent`'s and node-red's models equal `config_roles` as a sorted JSON array (`["chat-tasks"]`).
  - `classify` becomes `chat-tasks` everywhere.
  - "node-red key may use roles only" calls `chat-tasks`, then `gpt-oss-120b@coreweave`, which is refused.
  - The edit outside the script sets `models:["gpt-oss-120b@coreweave"]`, so the restore to `["chat-tasks"]` shows.
- [ ] **Step 2:** Run the `rapidselector.bats` test locally. Expected: FAIL, because setup-keys still has its own values and calls the gateway.
- [ ] **Step 3:** Implement `load_home_env` and the changes in `setup-keys.sh`.
- [ ] **Step 4:** Run `tests/rapidselector.bats` locally and `bash -n scripts/setup-keys.sh`. Expected: pass. `tests/keys.bats` waits for Task 9.
- [ ] **Step 5:** Commit: `feat: setup-keys.sh reads budgets and limits from config/home.env`.

### Task 5: The level 1 stack suites on the example

**Files:**
- Modify: `tests/gateway.bats`, `tests/budgets.bats`, `tests/budget-global.bats`, `tests/compose.lowbudget.yml` (comment), `tests/smoke.bats`, `tests/chat.bats`, `tests/gateway-api.bats`, `tests/ops-scripts.bats`, `tests/resilience.bats`, `tests/stack.bats`, `tests/drain.bats` (nothing changes, as `qwen3.8` and its price are kept; check it)

**Interfaces:**
- Consumes: the example values (Global constraints), `config_count`, `config_roles` (Task 1).

All of these need Docker. The change is the test itself: the code under test is unchanged after Tasks 1–4. They are verified in Task 9.

- [ ] **Step 1: Model names.** Everywhere in these files, `classify` becomes `chat-tasks`, and `gpt-oss-120b@deepinfra` / `gpt-oss-20b@deepinfra` / `summarise` become `gpt-oss-120b@coreweave`. An expected upstream `mistralai/mistral-small-3.2-24b-instruct` becomes `meta-llama/llama-3.1-8b-instruct`, and `openai/gpt-oss-20b` becomes `openai/gpt-oss-120b`.
- [ ] **Step 2: Cost per call.** `chat-tasks` costs a fifth of `classify`'s output price, so each `fake_tokens 100 100000` that aims at "about $0.02 a call" becomes `fake_tokens 100 500000` (100 × $0.02/M + 500000 × $0.04/M ≈ $0.02). That is in `budgets.bats`, `budget-global.bats` and `resilience.bats` (the first test), with their header comments.
- [ ] **Step 3: `gateway.bats`.** `ENTRIES` holds the example's three rows:

  ```
  chat-tasks|meta-llama/llama-3.1-8b-instruct|deepinfra/fp8|0.00000002|0.00000004|2048|role|false
  gpt-oss-120b@coreweave|openai/gpt-oss-120b|coreweave/fp4|0.00000003|0.00000017|8192|experiment|true
  qwen3.8-2.4t-a95b@siliconflow|qwen/qwen3.8-2.4t-a95b|siliconflow/fp8|0.000002|0.000006|8192|experiment|true
  ```

  The model info test compares with `$(config_count)` and `$(config_roles | wc -l)`, not 11 and 4. "spend is above zero without upstream cost" expects `100 * 0.00000002 + 50 * 0.00000004`. The streamed-call test uses `gpt-oss-120b@coreweave` and its `model_group`. The "configured price gives" figure in the finding becomes 0.000004.
- [ ] **Step 4: `budget-global.bats`.** The sed becomes `s/^  max_budget: 10$/  max_budget: 0.05/` on `"$RAPIDSELECTOR_GATEWAY_CONFIG"`, and its `grep -q` guard stays. Update the overlay's comment.
- [ ] **Step 5: `smoke.bats`.** The role loop reads `config_roles`. "--all covers 11 names" becomes "--all covers every name" and compares with `$(config_count)`.
- [ ] **Step 6:** Run `grep -nE 'classify|summarise|gpt-oss-20b|@deepinfra|mistral|gateway/config.yaml|\b11\b' tests/*.bats tests/*.yml tests/fakes/*.py`. Expected: hits only in `tests/smoke-noprice.bats` (it uses `tests/config.noprice.yaml`, its own config with `classify`) and in counts unrelated to the config. Read each remaining hit.
- [ ] **Step 7:** Commit: `test: the level 1 suites use the example config`.

### Task 6: `scripts/copy-config.sh`

**Files:**
- Create: `scripts/copy-config.sh`, `tests/copy-config.bats`

**Interfaces:**
- Consumes: `set_config_paths`, `load_env_file`, `die` (`lib.sh`); `check-prices.sh --rules-only` (Tasks 1 and 2).
- Produces: `scripts/copy-config.sh to|from [<user@host>]`.
  - **Local files:** `$GATEWAY_CONFIG` and `$HOME_ENV`. **Remote files:** always `<remote dir>/config/gateway.yaml` and `<remote dir>/config/home.env`.
  - **Remote dir:** `RAPIDSELECTOR_REMOTE_DIR` (from the environment, or from the local `$HOME_ENV` through `load_env_file` if that file exists), with a leading `~/` removed. Otherwise this clone's path relative to `$HOME`. If the clone is not under `$HOME` and nothing is set, exit 2: `set RAPIDSELECTOR_REMOTE_DIR in config/home.env`. A relative path is relative to the remote home directory.
  - **The host:** the argument. If none is given, it asks `Host (user@host): ` on stderr and reads it from stdin. An empty answer is exit 2.
  - **Transport:** exactly one `ssh` call per run, so there is one password prompt. Quote the remote paths with `printf %q`.
    - `to`: `tar -C <staging> -cf - gateway.yaml home.env | ssh <host> "cd <dir> && mkdir -p config && tar -C config -xf -"`. The staging folder holds the two local files under their fixed names.
    - `from`: `ssh -n <host> "cd <dir>/config && tar -cf - gateway.yaml home.env" | tar -C <staging> -xf -`.
  - **`to`:**
    1. Both local files must exist, or exit 2.
    2. Run `RAPIDSELECTOR_HOME_ENV="$HOME_ENV" check-prices.sh --rules-only "$GATEWAY_CONFIG"`, with its output shown. Exit 1 there means refuse: exit 1, `nothing copied: a rule is broken`. Any other non-zero means exit 2.
    3. Copy. If `ssh` fails, exit 2: `could not copy to <host>:<dir>/config (no clone there, or SSH failed)`.
    4. On success, print `copied gateway.yaml and home.env to <host>:<dir>/config`, then the next steps on the host: `./rapidselector.sh restart gateway`, and `./rapidselector.sh run-script scripts/setup-keys.sh` (if a name or a budget changed).
  - **`from`:**
    1. Fetch into staging. If `ssh` fails, exit 2: `could not copy from <host>:<dir>/config (files missing there, or SSH failed)`.
    2. List the local files that exist and differ (`cmp -s`). If any do, ask `Overwrite <files>? (y/N) ` and read the answer from stdin. Anything but `y` or `Y` means exit 1, `nothing changed`.
    3. Move both files into place (`mkdir -p` the local folder first) and print what was written.
    4. Identical files need no prompt.
  - **Usage:** anything else is exit 2 with a usage line.
  - The script never names, reads or writes `.env`.

- [ ] **Step 1: Write the failing tests** in `tests/copy-config.bats`. In `setup`:
  - Make a fake remote home `$BATS_TEST_TMPDIR/remote`, holding a clone folder `code/rapid-selector`, and a `.env` there with `SECRET=x`.
  - Make local files `$BATS_TEST_TMPDIR/local/gateway.yaml` and `local/home.env`, copied from the examples, and export the two variables to them.
  - Export `RAPIDSELECTOR_REMOTE_DIR=code/rapid-selector`.
  - Put a stand-in `ssh` first on `PATH`. It appends `$*` to `$BATS_TEST_TMPDIR/ssh.log`, skips options (`-n`, `-o <value>`), takes the first other argument as the host and the rest as the command, runs `cd "$BATS_TEST_TMPDIR/remote" && bash -c "$command"` with stdin passed through, and then, **only when it got no `-n`**, drains what is left of stdin (`cat >/dev/null`). It exits with the command's status.

  Tests:
  - `to copies both files and prints the next steps`: the remote files equal the local ones, the output contains `restart gateway`, and `ssh.log` has exactly one line.
  - `to refuses a broken rule and sends nothing`: a local `home.env` with `BUDGET_TEAM_EXPERIMENTS=99` gives exit 1, no `ssh.log`, and no remote `config/`.
  - `to a host without the clone exits 2 and creates nothing` (review focus 4): `RAPIDSELECTOR_REMOTE_DIR=code/elsewhere` gives exit 2, and `$BATS_TEST_TMPDIR/remote/code/elsewhere` does not exist.
  - `to without local home.env exits 2`.
  - `from writes the files when there are none locally`: remote files exist, local ones are removed, and the result is exit 0 with the local files equal to the remote ones.
  - `from asks before overwriting, and no keeps them`: the local files differ. With `printf 'n\n'` on stdin the result is exit 1 and the local files are unchanged.
  - `from overwrites on y, after ssh has run` (review focus 3): `printf 'y\n'` on stdin gives exit 0 and local files equal to the remote ones.
  - `from with files missing on the host exits 2`.
  - `the host is asked for when not given`: stdin `pi@sandbox\n` gives `pi@sandbox` in `ssh.log`.
  - `the remote folder defaults to the clone's place under HOME`: unset `RAPIDSELECTOR_REMOTE_DIR`, and run `to` with `HOME="$(dirname "$(dirname "$REPO")")"`. Whatever the exit code, `ssh.log` contains `$(basename "$(dirname "$REPO")")/$(basename "$REPO")`.
  - `the remote folder comes from home.env`: `RAPIDSELECTOR_REMOTE_DIR` is unset in the environment and set in the local `home.env`, and it is used.
  - `.env is never touched`: after `to` and then `from`, the remote `.env` still holds exactly `SECRET=x`, and `ssh.log` has no `.env` that is not part of `home.env` (`! grep -E '(^|[^a-z])\.env' ssh.log`).
  - `wrong usage exits 2`: `copy-config.sh sideways`.
- [ ] **Step 2:** Run `npx --yes bats@1.11.0 tests/copy-config.bats`. Expected: FAIL (no script).
- [ ] **Step 3:** Implement `scripts/copy-config.sh` (executable, `set -euo pipefail`, sources `lib.sh`; staging in `mktemp -d`, removed on exit).
- [ ] **Step 4:** Run `npx --yes bats@1.11.0 tests/copy-config.bats tests/checks.bats`. Expected: all pass.
- [ ] **Step 5:** Commit: `feat: scripts/copy-config.sh copies config/ to the host or from it`.

### Task 7: Docs, and the owner's procedure

**Files:**
- Create: `config/README.md`, `docs/test-procedures/config-folder.md`
- Modify: `scripts/README.md`, `README.md`, `docs/user-guide.md`, `docs/requirements.md`, `docs/roadmap.md`, `docs/onboarding.md`, `CLAUDE.md` (repository structure only)

- [ ] **Step 1: `config/README.md`.**
  - The rule (`scripts/` runs, `config/` is yours).
  - Each file: what it holds, which scripts read it, and that it is ignored by git.
  - Starting from the examples: `cp config/gateway.example.yaml config/gateway.yaml`, and the same for `home.env`, then edit.
  - `chat-tasks` must stay, pointed at the cheapest model.
  - The team budgets must add up to at most `max_budget`.
  - Copying: `scripts/copy-config.sh to` and `from`.
  - No secrets here; they stay in `.env`.
  - `RAPIDSELECTOR_GATEWAY_CONFIG` and `RAPIDSELECTOR_HOME_ENV` exist for the tests only.
- [ ] **Step 2: `scripts/README.md`.**
  - The rule at the top.
  - A `copy-config.sh` row (secrets: none, the SSH password goes to `ssh`; cost: nothing; exit codes 0, 1, 2).
  - `check-prices.sh`'s row names `config/gateway.yaml` and `config/home.env`, and `setup-keys.sh`'s row says its budgets come from `config/home.env`.
  - Exit code 5 reads `config/gateway.yaml or config/home.env breaks a rule`.
  - `lib.sh` also holds the only list of `home.env` names.
  - Every other `gateway/config.yaml` becomes `config/gateway.yaml`.
- [ ] **Step 3: `README.md`.**
  - First setup gets a step: copy the two examples into place and edit them (pointing to `config/README.md`).
  - "The model list should show 11 names" becomes "the names in your `config/gateway.yaml`".
  - Every other `gateway/config.yaml` becomes `config/gateway.yaml`.
  - The address table is unchanged.
- [ ] **Step 4: `docs/user-guide.md`.** Every task that edited `gateway/config.yaml` or a script's values (add a model or name, point a role, add or remove a role, change a budget) now follows the same sequence:
  1. Edit `config/` here.
  2. Run `scripts/check-prices.sh` here.
  3. Run `scripts/copy-config.sh to`.
  4. On the host, `./rapidselector.sh restart gateway`, then `setup-keys.sh` if a name or a budget changed, then the smoke test.

  No commit is needed. `rules ok: 11 entries` becomes `rules ok: N entries` (one per entry).
- [ ] **Step 5: `docs/requirements.md`, `docs/roadmap.md`, `docs/onboarding.md`.** Change `gateway/config.yaml` to `config/gateway.yaml`, except in dated records. Replace the parked "repository as code for several homes" in the roadmap with one line saying it became this work (spec and plan paths, 2026-11-12). The onboarding's "the 11 names" becomes "the names in `config/gateway.yaml`". Leave `docs/decisions.md`, `docs/provider-facts.md`, the specs, the plans and `docs/test-procedures/phase-0.md` and `ops-scripts.md` unchanged: they are dated records.
- [ ] **Step 6: `CLAUDE.md`.** In the repository structure only, add `├── config/         # each home's own settings: gateway.yaml, home.env (examples in git)` and change `gateway/` to `# request guard`. Change nothing else (the owner's decision, 2026-11-11).
- [ ] **Step 7: `docs/test-procedures/config-folder.md`**, the spec's 5 steps as the owner's procedure, written in the style of `docs/test-procedures/ops-scripts.md`. Each step says what to run, what to see and what it costs. The commands are short, and secrets are never shown. The order matters and is stated:
  1. Here, before the merge: Task 8's checks have passed.
  2. Here, after the merge and `git pull` on `main`: `scripts/copy-config.sh to pi@sandbox`, then check that `sandbox`'s `config/` holds both files (`ls ~/code/rapid-selector/config` on `sandbox`).
  3. On `sandbox`: `git pull`, `./rapidselector.sh restart gateway` (it should show `rules ok: 12 entries`), then `./rapidselector.sh up`. Then `docker inspect rapidselector-chat` filtered for `TASK_MODEL_EXTERNAL` should show `chat-tasks`.
  4. `./rapidselector.sh run-script scripts/setup-keys.sh`: `team:permanent` with 5 names, `team:experiments` with 12, and budgets 8 / 24 / 4 / 1 as before.
  5. `status.sh`; the smoke test, then `--name chat-tasks`. Its cost is confirmed with the owner first: well under $0.01. Then one new chat in Open WebUI gets a title (a fraction of a cent).
- [ ] **Step 8:** Run `grep -rn "gateway/config.yaml" README.md CLAUDE.md scripts config docs/user-guide.md docs/requirements.md docs/roadmap.md docs/onboarding.md`. Expected: no hits, or only dated lines you have read.
- [ ] **Step 9:** Commit: `docs: config/ in the README, user guide and scripts' README; the owner's procedure`.

### Task 8: The owner's own `config/` files (spec step 1)

**Files (in the main checkout, `/home/xivind/code/rapid-selector/config/`, git-ignored, never committed):**
- Create: `config/gateway.yaml`, `config/home.env`

- [ ] **Step 1:** In the main checkout (on `main`, where `gateway/config.yaml` is still tracked), run `mkdir -p config && cp gateway/config.yaml config/gateway.yaml`. Add the role `chat-tasks` as the last entry under `# --- Roles (permanent use) ---`, written exactly like the `llama-3.1-8b-instruct@deepinfra` entry, but with `model_name: chat-tasks` and `rapidselector_kind: role`. Write `config/home.env` from the worktree's `config/home.example.env`, with the owner's values from Global constraints and the same comments.
- [ ] **Step 2:** Run `git -C /home/xivind/code/rapid-selector status --short`. Expected: nothing about `config/` once the branch is merged. Before the merge, `main`'s `.gitignore` does not list them yet, so expect `?? config/`, and **do not add it**.
- [ ] **Step 3:** Run the rules check and the online price check with the worktree's scripts: `RAPIDSELECTOR_HOME_ENV=<main>/config/home.env .worktrees/config-folder/scripts/check-prices.sh <main>/config/gateway.yaml`. Expected: `rules ok: 12 entries` and 12 `ok` lines, exit 0. This is OpenRouter's public list: no cost.
- [ ] **Step 4:** Run `diff <(git -C <main> show main:gateway/config.yaml) <main>/config/gateway.yaml`. Expected: only the added `chat-tasks` block. Then compare `home.env`'s values with `git show main:scripts/setup-keys.sh` and `main:scripts/check-prices.sh`: 8, 24, 4, 1, 30, 100000, and the four providers.
- [ ] **Step 5:** Report the results. There is nothing to commit.

### Task 9: Verification, the cloud Docker run, and the PR

- [ ] **Step 1:** Run, here: `npx --yes bats@1.11.0 tests/checks.bats tests/copy-config.bats tests/ops-logic.bats tests/smoke-args.bats`. Then run `tests/rapidselector.bats` and `tests/ops-wiring.bats` with the fakes as in "For developers on this machine", with `FAKE_GATEWAY_CONFIG=<worktree>/config/gateway.example.yaml`. Expected: all pass. Run `bash -n` on every changed script.
- [ ] **Step 2:** Push the branch `config-folder`. The cloud Docker run (the owner starts it, as before): `dockerd > /tmp/dockerd.log 2>&1 &`, then `tests/run.sh`. Expected: `All N test files passed.` (19 files, `copy-config.bats` included). Record the count and any findings.
- [ ] **Step 3:** Use superpowers:requesting-code-review on the branch, then superpowers:finishing-a-development-branch. Open a PR to `main`. The owner merges.
- [ ] **Step 4:** On `main`: update `docs/test-procedures/phase-0-status.md`. "Next" points at the procedure `docs/test-procedures/config-folder.md`, and "For developers on this machine" gives `FAKE_GATEWAY_CONFIG=<repo>/config/gateway.example.yaml`. Commit and push. The owner's procedure follows, one step at a time.
