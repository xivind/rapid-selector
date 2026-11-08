# Scripts instead of tower: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `tower` with `scripts/status.sh` and `scripts/reconcile.sh` (screen and Prometheus output), a rules check that guards `./rapidselector.sh restart gateway`, task-oriented documentation, and a complete cleanup procedure for everything tower left behind.

**Architecture:** Bash scripts with `jq`, like the existing ones. Each new script fetches with small helpers in `scripts/lib.sh` and hands the raw JSON to one `jq` program in `scripts/jq/`, which returns a report object; the script renders that as text or Prometheus format and sets the exit code from it. The `jq` programs are tested locally against fixtures; the wiring is tested at level 1 against real LiteLLM and the fake upstream.

**Tech stack:** bash, `jq` (must work with jq 1.6, the version on this machine), `curl`, bats 1.11.0, Docker Compose for level 1, LiteLLM v1.106.6.

**Spec:** `docs/superpowers/specs/2026-11-08-scripts-instead-of-tower-design.md`. Read it first; this plan argues from it.

## Global constraints

- Work in a worktree `.worktrees/ops-scripts` on a new branch **`ops-scripts`** created from `phase-0-walkthrough`. Records (`docs/decisions.md`, `docs/test-procedures/phase-0-status.md`) are committed on `phase-0-walkthrough`, not here.
- Nothing is copied from `tower-part-1a` except what Task 1 lists. No file under `tower/`, no tower spec, plan or procedure.
- Routine scripts live in `scripts/`; test-only scripts in `tests/`.
- Every script starts with a header: what it does and why, how to run it, which secrets it needs, what it costs, what its exit codes mean.
- Exit codes of routine scripts: `0` all well, `1` needs a look, `2` a source could not be read or wrong usage. `lib.sh` keeps `3` (missing value) and `4` (secrets-service). `rapidselector.sh` gets `5` (config breaks a rule; not restarted).
- No secret in a process list, URL, log or output: keys go to `curl` as a header on stdin or a private file (`api()` in `lib.sh` shows how), values to `jq` through its environment.
- Every part works in bare-bones mode (`SECRETS_SOURCE=env`, no Prometheus) and extended mode (`secrets-service`, `--prometheus`).
- Balance warning below **$10**; budgets warn above **80%** spent; management key warns within **30 days**; reconciliation flags a difference above **max($0.05, 5% of OpenRouter's figure)**; reconcile window default **7** completed UTC days, at most **30**.
- Allowed hosts (tag prefix before `/`): `cloudflare`, `coreweave`, `deepinfra`, `siliconflow`.
- OpenRouter's base URL comes from `OPENROUTER_API_BASE_URL`, default `https://openrouter.ai/api/v1`; the inference key's name from `OPENROUTER_INFERENCE_KEY_NAME`, default `rapidselector-gateway`.
- Commands the owner types stay short; anything longer is a committed script.
- **Where tests run:** this machine has no Docker. Run locally what needs no Docker (`tests/ops-logic.bats`, `tests/checks.bats`, `bash -n`). Every bats file that needs Docker is written test-first in its task and run in the cloud Docker run (Task 12); a task is not "verified" until then, and its report says so.

## Review focus

1. **OpenRouter answers 401 for an expired management key** (2027-11-07): `status.sh` and `reconcile.sh` must exit 2 with "management key rejected (expired?)", not print a balance of 0. Test in Task 5.
2. **A day with no activity on one side** (a model only in LiteLLM's table, e.g. 11-05 `llama-3.2-1b@cloudflare` at $0.000001): one line with 0 on the other side, not flagged under the $0.05 floor, not dropped. Test in Task 6.
3. **`/user/daily/activity` with more than one page**: every page's models are added up. Test in Task 6 (fixture with `has_more: true`).
4. **`config.yaml` with a field the parser cannot read** (an entry missing `only:` or a price): the rules check fails closed, naming the entry and field, rather than passing. Test in Task 3.
5. **`restart` with no service named** also restarts the gateway, so the rules check runs then too. Test in Task 4.

---

### Task 1: Branch, and carry over the shared infrastructure from `tower-part-1a`

**Files:**
- Create the branch and worktree: `git worktree add .worktrees/ops-scripts -b ops-scripts phase-0-walkthrough`
- Take from `tower-part-1a` unchanged (`git checkout tower-part-1a -- <path>`): `tests/fakes/upstream.py`, `tests/fakes.bats`, `tests/compose.fakes.yml`, `tests/checks.bats`.
- Take from `tower-part-1a`, then edit out tower: `scripts/lib.sh`, `scripts/setup-keys.sh`, `tests/helpers.bash`, `tests/compose.test.yml`, `tests/keys.bats`, `tests/gateway-api.bats`.
- Modify by hand (do not take tower's version): `tests/rapidselector.bats`, `.env.example`, `docs/provider-facts.md`.
- Create: `tests/fixtures/` with `gateway-daily-activity.json` and `gateway-team-info.json` copied from `tower-part-1a:tower/tests/samples/` (real LiteLLM v1.106.6 responses, test key values already replaced).

**Interfaces:**
- Produces: secret names `OPENROUTER_MANAGEMENT_KEY` and `KEY_SCRIPTS` in `RAPIDSELECTOR_SECRETS` (in that order, after `KEY_SMOKE_TEST`, and no `TOWER_*`); `api()` with the key as a header file and the body on stdin; `key_hash <value>` in `setup-keys.sh`; `ensure_scripts_key` in `setup-keys.sh` with variables `SCRIPTS_ROLE` (start: `proxy_admin_viewer`) and `SCRIPTS_ROUTES` (start: `["/global/spend","/team/info","/user/daily/activity"]`); helpers `openrouter_state <json>` and `openrouter_requests` in `tests/helpers.bash`; `test_env KEY_SCRIPTS`.

- [ ] **Step 1:** Create the worktree and take the files listed above.
- [ ] **Step 2:** De-tower them. `lib.sh`: secrets list as in Interfaces. `helpers.bash`: drop the `TOWER_PORT` line; the key pattern becomes `KEY_*`. `compose.test.yml`: drop the `tower:` service and the comment's mention of tower; keep `fake-upstream`'s `FAKE_MANAGEMENT_KEY` and `FAKE_INFERENCE_KEY_NAME`. `setup-keys.sh`: `ensure_tower` becomes `ensure_scripts_key` (user `scripts`, alias `scripts`, role `$SCRIPTS_ROLE`, `$SCRIPTS_ROUTES`, `KEY_SCRIPTS`, `auto_create_key: false` kept); the summary loop lists `$KEY_SCRIPTS` instead of the tower key; the comment above the routes says why each is there.
- [ ] **Step 3:** `tests/rapidselector.bats`: add `OPENROUTER_MANAGEMENT_KEY KEY_SCRIPTS` to both secret lists (stub docker and `all_secrets_lines`). Keep phase 0's "update runs pull then up -d" as it is.
- [ ] **Step 4:** `.env.example`: add `OPENROUTER_INFERENCE_KEY_NAME=rapidselector-gateway`, `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT=` (ISO date; `status.sh` warns 30 days before), `OPENROUTER_MANAGEMENT_KEY=` (comment: "OpenRouter MANAGEMENT key, one-year expiry. Borrowed per run by `scripts/status.sh` and `scripts/reconcile.sh` to read the balance and activity; no service holds it. It cannot make inference calls, but it can create and change keys: treat it as the most sensitive secret."), `KEY_SCRIPTS=` (read-only gateway key for the scripts; generate with `echo "sk-$(openssl rand -hex 24)"`).
- [ ] **Step 5:** `tests/keys.bats`: tower's key test becomes **"scripts key exists with only its routes"**: alias `scripts`, user `scripts`, no team and no budget, `allowed_routes` equal to `$SCRIPTS_ROUTES` as `setup-keys.sh` defines it (read it from the script, do not copy the list), user role equal to `$SCRIPTS_ROLE`, exactly one key owned by user `scripts`, and the key value not in setup-keys' output.
- [ ] **Step 6:** `tests/gateway-api.bats`: tower's key becomes `KEY_SCRIPTS` (rename `tw` to `sk`, `TOWER_KEY` to `SCRIPTS_KEY`, the header comment to the scripts). Keep the tests for daily activity, team info and the global budget; remove the model-info, key-list and block/unblock tests (the scripts do not use them). Its `save` writes `daily-activity` and `team-info` into `tests/.artifacts/gateway-api/`, so a later run can refresh `tests/fixtures/` by hand. The refusal test asserts 403 (or 401 for master-key-only routes) for: `POST /key/generate`, `POST /key/update`, `POST /key/block`, `POST /model/new`, `POST /global/spend/reset`, `POST /v1/chat/completions`, `POST /openrouter/v1/chat/completions`, `GET /key/list`, `GET /model/info`.
- [ ] **Step 7:** Add a test **"the scripts' key reads daily activity for every user"**: after a call with `KEY_SMOKE_TEST` and one with `KEY_CHAT`, `GET /user/daily/activity` for today with `KEY_SCRIPTS` returns 200 and `breakdown.api_keys` holds both keys' hashes. This decides `SCRIPTS_ROLE` in Task 12.
- [ ] **Step 8:** `docs/provider-facts.md`: bring over every section `tower-part-1a` added except "Tower dependencies" and "htmx", rewording "tower" to "the scripts" where it names our client (keep "tower" only in dated statements of what was tried then). Add under LiteLLM: **daily table merges names sharing a model id** (the cause from `docs/decisions.md`, 2026-11-07, with the schema and queue key, and "LiteLLM's admin UI usage view has the same limit"). Add under OpenRouter's management API: **`/api/v1/activity`'s `provider_name` is the full endpoint tag** (`siliconflow/fp8`, `deepinfra/bf16`, `coreweave/fp4`), and `model` is the id without `openrouter/`, seen live on 2026-11-07.
- [ ] **Step 9:** Run `bash -n` on every changed script, and `npx --yes bats@1.11.0 tests/checks.bats` (no Docker). Expected: all pass. `grep -rn -i tower scripts tests .env.example` finds nothing.
- [ ] **Step 10:** Commit: `ops-scripts: carry over the shared infrastructure from tower-part-1a, without tower`.

### Task 2: Folders and headers

**Files:**
- Move: `tests/check-prices.sh` → `scripts/check-prices.sh`; `scripts/drain-balance.sh` → `tests/drain-balance.sh` (`git mv`).
- Modify: `tests/checks.bats`, `tests/drain.bats` (paths); `README.md` and `docs/test-procedures/phase-0.md` where a step still to be run names the old path; the headers of `scripts/lib.sh`, `scripts/setup-keys.sh`, `scripts/smoke-test.sh`, `scripts/check-prices.sh`, `tests/drain-balance.sh`, `tests/check-arm64.sh`.

**Interfaces:**
- Produces: `scripts/check-prices.sh [config]` at its new path (Task 3 extends it).

- [ ] **Step 1:** Move the two scripts; fix the paths in the bats files (`$REPO/scripts/check-prices.sh`, `run-script tests/drain-balance.sh`). `drain-balance.sh` sources `$ROOT/scripts/lib.sh`, which still resolves.
- [ ] **Step 2:** Bring every listed header to the global constraint's form (what and why, how to run, secrets, cost, exit codes). Keep the wording the scripts already have where it fits.
- [ ] **Step 3:** Run `npx --yes bats@1.11.0 tests/checks.bats`. Expected: pass. `tests/drain.bats` needs Docker (Task 12).
- [ ] **Step 4:** Commit: `ops-scripts: routine scripts in scripts/, test scripts in tests/, a header on each`.

### Task 3: The rules check

**Files:**
- Modify: `scripts/check-prices.sh`
- Test: `tests/checks.bats`

**Interfaces:**
- Produces: `scripts/check-prices.sh [--rules-only] [config]`. Exit `0` every entry passes; `1` an entry fails (one `FAIL <name>: <rule>` line each); `2` OpenRouter's list cannot be read (not possible with `--rules-only`). Without `--rules-only`: the rules first, then the prices, as today. Header says what both parts check.

- [ ] **Step 1: Write the failing tests** in `tests/checks.bats`. A helper `broken_config <sed expression>` writes `$BATS_TEST_TMPDIR/config.yaml` from `gateway/config.yaml` with the change applied to the first entry. One test per rule, each `run "$REPO/scripts/check-prices.sh" --rules-only "$BATS_TEST_TMPDIR/config.yaml"`, asserting `status -eq 1` and the `FAIL` line naming the entry and the rule:
  - "rules: the real config passes" (no change, `--rules-only`, status 0, no network: `ZDR_ENDPOINTS_FILE` unset and `PATH` without `curl` still passes)
  - "rules: fallbacks on" (`allow_fallbacks: true`)
  - "rules: zero data retention off" (`zdr: false`)
  - "rules: data collection allowed" (`data_collection: allow`)
  - "rules: order and only differ" (`only` set to another tag)
  - "rules: more than one host in order" (`order: ["deepinfra/bf16", "coreweave/fp4"]`)
  - "rules: host not allowed" (tag `novita/fp8` in both)
  - "rules: price zero" (`input_cost_per_token: 0`)
  - "rules: no max_tokens" (line deleted)
  - "rules: a :free model" (model ending `:free`)
  - "rules: a wildcard model" (`model: openrouter/*`)
  - "rules: a field that cannot be read fails closed" (the `only:` line deleted; `FAIL` names the field)
  - "prices still checked after the rules" (a changed price without `--rules-only` still fails as before)
- [ ] **Step 2:** Run `npx --yes bats@1.11.0 tests/checks.bats`. Expected: the new tests fail.
- [ ] **Step 3:** Extend the script's `awk` parser to read, per entry, `max_tokens`, `order`, `only`, `allow_fallbacks`, `zdr`, `data_collection` as well; check the rules in bash; a field left at `-` fails as "cannot read <field>".
- [ ] **Step 4:** Run the tests. Expected: all pass.
- [ ] **Step 5:** Commit: `ops-scripts: check-prices checks the allowlist rules, also on their own with --rules-only`.

### Task 4: `restart gateway` refuses a config that breaks a rule

**Files:**
- Modify: `rapidselector.sh`
- Test: `tests/rapidselector.bats`

**Interfaces:**
- Consumes: `scripts/check-prices.sh --rules-only [config]` (Task 3).
- Produces: `./rapidselector.sh restart [services...]`: when no service is named or `gateway` is among them, runs the rules check on `${RAPIDSELECTOR_GATEWAY_CONFIG:-$RAPIDSELECTOR_ROOT/gateway/config.yaml}` first; on failure prints the check's lines and "gateway not restarted: gateway/config.yaml breaks a rule" and exits `5` without calling docker.

- [ ] **Step 1: Write the failing tests** (stub docker as in the file):
  - "restart gateway runs the rules check and then docker" (good config: the docker log has `ARGS=compose restart gateway`)
  - "restart gateway with a broken rule exits 5 without calling docker" (config with `allow_fallbacks: true` through `RAPIDSELECTOR_GATEWAY_CONFIG`; no `ARGS=` line; output names the entry)
  - "restart with no service checks the rules too" (broken config, `restart`, exit 5)
  - "restart chat is not checked" (broken config, `restart chat`, docker called)
- [ ] **Step 2:** These need the fake secrets-service container, so they run in Task 12. Check them with `bash -n` now.
- [ ] **Step 3:** Implement the branch in `rapidselector.sh`, before the final `exec docker compose "$@"`; update the header comment.
- [ ] **Step 4:** Commit: `ops-scripts: restart gateway refuses a config that breaks a rule`.

### Task 5: `status.sh`

**Files:**
- Create: `scripts/status.sh`, `scripts/jq/status.jq`, `tests/ops-logic.bats`, `tests/fixtures/openrouter-credits.json`, `tests/fixtures/openrouter-keys.json`, `tests/fixtures/openrouter-key.json`, `tests/fixtures/gateway-global-spend.json`, `tests/ops-scripts.bats`
- Modify: `scripts/lib.sh`

**Interfaces:**
- Produces in `lib.sh`:
  - `gw_read <path>`: GET on the gateway with `KEY_SCRIPTS` as a header file; prints the body; returns 1 on HTTP ≥ 400 or no answer, with the status on stderr.
  - `or_read <path>`: GET on `${OPENROUTER_API_BASE_URL:-https://openrouter.ai/api/v1}<path>` with `OPENROUTER_MANAGEMENT_KEY` the same way, `--max-time 30`; returns 1 likewise, and on 401 prints "management key rejected (expired?)" to stderr.
- Produces `scripts/jq/status.jq`: called as `jq -n --arg now <ISO UTC> --arg expires <ISO date or ""> --arg key_name <name> --argjson credits … --argjson keys … --argjson key … --argjson global … --argjson teams '[<team_info>, …]' -f scripts/jq/status.jq`, returns:
  `{balance_usd, key: {name, disabled, limit_usd, remaining_usd, usage_day_usd, usage_week_usd, usage_month_usd, limit_reset}, forecast_month_usd, gateway: {spend_usd, budget_usd}, teams: [{id, spend_usd, budget_usd, reset_at}], management_key_days_left (null when expires is ""), warnings: [string]}`.
  The inference key's hash is found in `keys` by `name` before `key` is fetched (so the script fetches `/keys?include_disabled=true` first). Forecast: `usage_month_usd / max(days elapsed this month, 1) × days in month`. Warnings, one string each, in this order: balance below $10 (with "calls get slower and speed comparisons are unreliable"), inference key disabled, global or a team budget above 80% spent, a team's `budget_reset_at` not the 1st of next month at 00:00 UTC while OpenRouter's `limit_reset` is `monthly`, management key expiring within 30 days or expired.
- Produces `scripts/status.sh [--prometheus]`: exit `0` no warnings, `1` warnings, `2` a source unreadable (naming it). Text: one short screen, amounts with 2 decimals (`$0.0012` style below one cent), then the warnings. Prometheus (all gauges, with `# HELP` and `# TYPE`): `rapidselector_openrouter_balance_usd`, `rapidselector_openrouter_key_limit_usd`, `rapidselector_openrouter_key_remaining_usd`, `rapidselector_openrouter_key_usage_month_usd`, `rapidselector_openrouter_key_disabled` (0 or 1), `rapidselector_management_key_days_left` (left out when unknown), `rapidselector_status_warnings`, `rapidselector_status_last_run_timestamp_seconds`.

- [ ] **Step 1:** Fixtures. `gateway-global-spend.json` `{"spend": 1.23, "max_budget": 32.0}` (the shape in `provider-facts.md`). OpenRouter fixtures in the documented shapes (`provider-facts.md`, "Management API"): credits `{"data":{"total_credits":42.25,"total_usage":7.44}}`; keys `{"data":[{"hash":"…","name":"rapidselector-gateway",…}, {"hash":"…","name":"other",…}]}`; key `{"data":{limit, limit_remaining, limit_reset:"monthly", usage, usage_daily, usage_weekly, usage_monthly, disabled:false, …}}`. A header line in each OpenRouter fixture's companion note (`tests/fixtures/README.md`) says which shapes were seen live and which come from the docs.
- [ ] **Step 2: Write the failing tests** in `tests/ops-logic.bats` (no Docker; a helper `status_report [jq --argjson overrides]` runs `status.jq` on the fixtures with `now=2026-11-15T12:00:00Z`):
  - "status: balance is credits minus usage" (`balance_usd == 34.81`)
  - "status: the inference key is found by name" (`key.limit_usd` from the fixture, not the other key's)
  - "status: forecast for the month" (`usage_month_usd` 7.0 on day 15.5 of 30 → `13.548…`, compare to 2 decimals)
  - "status: no warnings on the fixtures" (`warnings == []`)
  - "status: balance below $10 warns" (credits giving 9.99)
  - "status: a disabled key warns"
  - "status: a team above 80% warns" (spend 19.3 of 24)
  - "status: a team resetting on another day warns" (`budget_reset_at` `2026-12-05T00:00:00Z`)
  - "status: management key within 30 days warns" (expires `2026-12-01`), and "…unknown gives null and no warning" (expires "")
- [ ] **Step 3:** Run `npx --yes bats@1.11.0 tests/ops-logic.bats`. Expected: fail (no `status.jq`).
- [ ] **Step 4:** Implement `status.jq` (jq 1.6: no `abs`, `pick`, `ltrimstr` is fine; dates with `fromdateiso8601`, `strftime`).
- [ ] **Step 5:** Run the logic tests. Expected: pass.
- [ ] **Step 6: Write the level 1 tests** in `tests/ops-scripts.bats` (`setup_file`: `stack_up`, `run_setup_keys`; helper `run_ops <script> [args]` runs it through `./rapidselector.sh run-script` with the test env and `OPENROUTER_API_BASE_URL=$FAKE_UPSTREAM_URL/api/v1`):
  - "status.sh shows the fake's balance and exits 0" (`openrouter_state '{"credits":{"total_credits":20,"total_usage":1}}'`; output has `$19.00`; status 0)
  - "status.sh exits 1 with a balance below $10" (`total_usage` 15)
  - "status.sh exits 2 when OpenRouter's credits fail" (`{"fail":"credits"}`; output names the credits)
  - "status.sh exits 2 with a rejected management key" (run with `OPENROUTER_MANAGEMENT_KEY=wrong`; "management key rejected")
  - "status.sh --prometheus prints every gauge" (each metric name above present once, values parse as numbers)
  - "status.sh prints no secret" (no value of `KEY_SCRIPTS`, `OPENROUTER_MANAGEMENT_KEY` or `LITELLM_MASTER_KEY` in stdout or stderr)
- [ ] **Step 7:** Implement `gw_read`, `or_read` and `status.sh`. Run `bash -n` and the logic tests.
- [ ] **Step 8:** Commit: `ops-scripts: status.sh, the balance, the key and the budgets on one screen`.

### Task 6: `reconcile.sh`

**Files:**
- Create: `scripts/reconcile.sh`, `scripts/jq/reconcile.jq`, `tests/fixtures/openrouter-activity.json`, `tests/fixtures/gateway-daily-activity-page2.json`
- Modify: `tests/ops-logic.bats`, `tests/ops-scripts.bats`

**Interfaces:**
- Consumes: `gw_read`, `or_read`, the key lookup by name (Task 5; factor it into `lib.sh` as `inference_key_hash` if both scripts need it).
- Produces `scripts/jq/reconcile.jq`: `jq -n --argjson gateway '[<page>, …]' --argjson activity <data array> --arg first <YYYY-MM-DD> --arg last <YYYY-MM-DD> -f scripts/jq/reconcile.jq` returns `{lines: [{day, model, gateway_usd, openrouter_usd, diff_usd, flagged}], days: [{day, gateway_usd, openrouter_usd, diff_usd, flagged}], flagged: <count of flagged lines>, max_abs_diff_usd}`. Gateway side: `results[].breakdown.models` with the `openrouter/` prefix removed, spend added over pages. OpenRouter side: rows with `date` (first 10 characters) between `first` and `last`, `usage` added over every `provider_name` per `model`. `diff_usd` is gateway minus OpenRouter; flagged when `|diff| > max(0.05, 0.05 × openrouter_usd)`. Lines sorted by day descending, then model.
- Produces `scripts/reconcile.sh [--days N] [--prometheus]`: the window is the N completed UTC days before today (default 7, 1–30, else exit 2 with the usage); it fetches every page of `/user/daily/activity?start_date=<first>&end_date=<last>&page=<n>` until `metadata.has_more` is false, and `/activity?api_key_hash=<inference key hash>`. Exit `0` nothing flagged, `1` flagged, `2` a source unreadable. Text: a table of day, model, gateway, OpenRouter, difference, with `!` on flagged lines and a total per day. Prometheus: `rapidselector_reconcile_flagged_lines`, `rapidselector_reconcile_max_abs_diff_usd`, `rapidselector_reconcile_window_days`, `rapidselector_reconcile_last_run_timestamp_seconds`.

- [ ] **Step 1:** `openrouter-activity.json` holds the 2026-11-05 and 11-06 rows from `docs/decisions.md`'s C2 entry, in the shape seen live: e.g. `{"date":"2026-11-06","model":"openai/gpt-oss-120b","provider_name":"deepinfra/bf16","usage":0.000830,"requests":…}` and `{"date":"2026-11-06","model":"openai/gpt-oss-120b","provider_name":"coreweave/fp4","usage":0.000184,…}`, plus `qwen/qwen3.8-2.4t-a95b` `siliconflow/fp8` 5.10 on 11-06. `gateway-daily-activity-page2.json` is the copied page with `metadata.page` 2, `has_more` false and one more model; set `has_more: true` in a copy of page 1 inside the test.
- [ ] **Step 2: Write the failing tests** in `tests/ops-logic.bats`:
  - "reconcile: two hosts of one model meet the gateway's one line" (11-06 `openai/gpt-oss-120b`: gateway 0.001018 vs OpenRouter 0.001014, not flagged)
  - "reconcile: a large difference is flagged" (gateway 5.10 vs OpenRouter 4.80 for qwen3.8: flagged, `diff_usd` 0.30)
  - "reconcile: under the floor is not flagged" (0.04 against 0)
  - "reconcile: a model on one side only keeps its line" (gateway-only model, `openrouter_usd` 0)
  - "reconcile: every page is added" (two pages, the second page's model present)
  - "reconcile: rows outside the window are left out"
  - "reconcile: day totals add the lines"
- [ ] **Step 3:** Run them. Expected: fail.
- [ ] **Step 4:** Implement `reconcile.jq`. Run. Expected: pass.
- [ ] **Step 5: Write the level 1 tests** in `tests/ops-scripts.bats`: "reconcile.sh matches the gateway's real spend" (calls through the gateway yesterday cannot be made, so: make calls, wait for spend, run with the fake's activity set to today's gateway figures and `RECONCILE_TODAY` set to tomorrow's date, an environment override the script documents as for tests only; exit 0), "reconcile.sh flags a difference" (activity off by $1; exit 1, `!` in output), "reconcile.sh --days 31 exits 2", "reconcile.sh --prometheus prints its gauges", "reconcile.sh prints no secret".
- [ ] **Step 6:** Implement `reconcile.sh`. Run `bash -n` and the logic tests.
- [ ] **Step 7:** Commit: `ops-scripts: reconcile.sh, LiteLLM's spend against OpenRouter's per day and model`.

### Task 7: The one-off cleanup scripts

**Files:**
- Create: `scripts/cleanup-tower-secrets.sh`, `scripts/cleanup-tower-user.sh`, `tests/cleanup.bats`

**Interfaces:**
- `scripts/cleanup-tower-secrets.sh`: run on the host without `rapidselector.sh` (its secrets are not complete until it has run). With `SECRETS_SOURCE=secrets-service`: reads the secret `rapidselector`, refuses with exit 4 if it has fewer than 9 fields, adds `KEY_SCRIPTS` (generated, `sk-` + 48 hex) if missing, removes `TOWER_PASSWORD`, `TOWER_SESSION_SECRET`, `TOWER_GATEWAY_KEY`, keeps every other field unchanged, writes it back, prints names and lengths only. Safe to run twice. With `SECRETS_SOURCE=env`: changes nothing and prints the `.env` lines to add (`KEY_SCRIPTS=` with a generated value is **not** printed; it says to generate one with the command from `.env.example`) and the `TOWER_*` lines to delete. Modelled on `tower-part-1a:scripts/add-tower-secrets.sh` (header file for the token, values through jq's environment).
- `scripts/cleanup-tower-user.sh`: run through `./rapidselector.sh run-script`; with the master key, deletes every key with alias `tower` and the user `tower` if they exist; prints what it removed; exit 0 also when nothing was there.
- Both headers say: one-off, for `docs/test-procedures/ops-scripts.md`, deleted from the repository once the owner has run them.

- [ ] **Step 1: Write the failing tests** in `tests/cleanup.bats` (fake secrets-service; and the stack for the user script):
  - "secrets: adds KEY_SCRIPTS and removes the three tower fields, keeping the rest" (blob with the 9 phase 0 fields, `OPENROUTER_MANAGEMENT_KEY` and the three `TOWER_*`; after: 11 fields, the 10 non-tower values unchanged, `KEY_SCRIPTS` starts with `sk-`)
  - "secrets: a second run changes nothing"
  - "secrets: fewer than 9 fields is refused with exit 4 and nothing written"
  - "secrets: env mode writes nothing and names the lines"
  - "secrets: output shows names and lengths, no value"
  - "user: removes user tower and its key" (create both with the master key first; after, `/key/list` has no alias `tower`, `/user/info?user_id=tower` is 404 or empty)
  - "user: a second run exits 0"
- [ ] **Step 2:** Implement both. Run `bash -n`.
- [ ] **Step 3:** Commit: `ops-scripts: one-off scripts that remove tower's secrets and gateway user`.

### Task 8: Remove tower from the repository's documents

**Files:**
- Modify: `CLAUDE.md`, `docs/requirements.md`, `docs/roadmap.md`, `README.md`
- Delete: `docs/superpowers/specs/2026-11-05-tower-part-1a-design.md`, `docs/superpowers/specs/2026-11-05-tower-part-1b-design.md`, `docs/superpowers/plans/2026-11-06-tower-part-1a.md`

- [ ] **Step 1:** `CLAUDE.md`, as the spec's "Docs that change" says: architecture diagram and table without `tower` (clients: Open WebUI, Node-RED, other apps, the operator scripts); the line "The chosen stack (LiteLLM, Postgres, Open WebUI with its arena, and promptfoo for benchmarks) covers our needs, so we build no service of our own (principle 5, reuse before build). What we build are operator scripts in `scripts/`."; principle 2's exception reworded ("The operator scripts `scripts/status.sh` and `scripts/reconcile.sh` borrow OpenRouter's management key per run, from the secret store or `.env`; no service holds it …"; keep the sentence on its sensitivity); "`tower` reads LiteLLM data through LiteLLM's API" becomes "the scripts"; "`tower` is the only interface we build" removed; backups without tower's SQLite; repo structure without `tower/`, with `scripts/` described as "operator scripts (status, reconcile, setup, smoke test, checks)".
- [ ] **Step 2:** `docs/requirements.md`: the `tower` section replaced by **"Operator scripts"**: status (what `status.sh` shows and when it warns), reconciliation, the guarded model change, the Prometheus output and cron (optional), the two modes, the kill switch through OpenRouter's dashboard and LiteLLM's admin UI (README). General lines without tower. The "Arena and benchmarking" section: Open WebUI's arena and promptfoo, nothing built in tower.
- [ ] **Step 3:** `docs/roadmap.md`: phase 1 becomes "Operator scripts instead of tower" (this plan), with the README dry run and two-factor authentication kept; the arena item no longer says "build in tower"; the parked "Tower engaging the kill switch by itself" removed; SearXNG's "because tower then shows what it costs" becomes "because the scripts and Grafana then show what it costs".
- [ ] **Step 4:** `README.md`: the `tower` row in the address table removed; a link to `scripts/README.md` and `docs/user-guide.md` under "Everyday commands"; the developers' note on `check-prices.sh` with its new path.
- [ ] **Step 5:** Delete the three files. `grep -rn -i tower --exclude-dir=.git .` finds it only in `docs/decisions.md`, `docs/test-procedures/phase-0-status.md` (rewritten in Task 11), the spec and this plan, and the one-off cleanup scripts.
- [ ] **Step 6:** Commit: `docs: tower removed; the stack covers our needs, and we build operator scripts`.

### Task 9: `scripts/README.md` and the optional Prometheus integration

**Files:**
- Create: `scripts/README.md`
- Modify: `README.md` (an optional-integration section)

- [ ] **Step 1:** `scripts/README.md`, for a person and an agent: a table of every routine script (what, when, secrets, cost, exit codes, including `lib.sh`'s 3 and 4 and the wrapper's 5); the order of use for first setup, a model change (from the spec, including that `restart gateway` checks the rules), the weekly and monthly checks; the two modes and what differs (in bare-bones mode the management key sits in `.env` beside the other secrets, said plainly); where tests live (`tests/`) and that the one-off cleanup scripts are temporary; a pointer to `docs/user-guide.md` for tasks.
- [ ] **Step 2:** `README.md`, "Optional: cost figures in Prometheus": what the two `--prometheus` outputs contain, and a cron example that runs both hourly through `./rapidselector.sh run-script`, writes to a temporary file, and moves it into `/var/lib/node_exporter/textfile/` only when the exit code is 0 or 1. Kept to short lines; if the line is long, a committed `scripts/write-metrics.sh` does the writing and cron calls it (builder's call). Say that the alert rules and dashboard belong to the home's own repository.
- [ ] **Step 3:** Commit: `docs: scripts/README.md, and cost figures in Prometheus as an option`.

### Task 10: The user guide

**Files:**
- Create: `docs/user-guide.md`

- [ ] **Step 1:** One section per task in the spec's list ("User documentation"), each with: when you need it; the commands (short lines, run from the repository on the host); what you should see; what it costs; what to do if it fails. Changing models and roles follows `scripts/README.md`'s order and names `setup-keys.sh` for allowed names, and what a role rename means for Node-RED (every client calling it must change at once; check the keys allowed it with LiteLLM's admin UI). Budgets: the order of limits from `CLAUDE.md` principle 1 and `setup-keys.sh`'s variables. Stopping all spending: the README's manual kill switch. A Grafana alert or `status.sh` warning: what each warning means and what to do. Nothing here describes LiteLLM's or OpenRouter's UIs beyond the step needed: the onboarding comes later.
- [ ] **Step 2:** Every command in it is checked against the scripts as they now are (names, options, paths).
- [ ] **Step 3:** Commit: `docs: a user guide for the tasks done most often`.

### Task 11: The owner's procedure

**Files:**
- Create: `docs/test-procedures/ops-scripts.md`

- [ ] **Step 1:** In the form of the phase 0 procedure (step, what to run or click, what you should see, cost), one step at a time. **Part A, cleanup**, the spec's steps 1–13 in its order, with the commands: A1 remove tower's container while on `tower-part-1a`; A2 `git fetch` and switch to `ops-scripts`; A3 `scripts/cleanup-tower-secrets.sh`; A4 `.env` lines; A5 `./rapidselector.sh up` and `ps` (three services healthy, no tower); A6 `setup-keys.sh` (the `scripts` row) and `cleanup-tower-user.sh`; A7 image, volume, build cache, base images (with the check that nothing else uses them); A8 the management key's name in OpenRouter's dashboard; A9 Prometheus target and Grafana group `LLM` (extended mode); A10 `production`'s local branch; A11–A13 are Claude's (GitHub branch, this machine, the repository search and records) and are listed so the owner sees them done. **Part B, the scripts:** B1 `status.sh` beside OpenRouter's dashboard (balance, limit, remaining, usage match within a few cents); B2 `reconcile.sh --days 7` (the 11-05 and 11-06 `gpt-oss-120b` lines now meet); B3 `check-prices.sh` on the live config; B4 `restart gateway` (rules pass, gateway healthy again); B5 the smoke test, under $0.01, the only cost; B6 `systemctl cat` of the node_exporter unit on `sandbox` shows the textfile directory (extended mode), and the cron line from the README, if the owner wants it now. A closing line: what Claude records, and that the onboarding comes after.
- [ ] **Step 2:** Commit: `docs: the owner's procedure for the cleanup and the scripts`.

### Task 12: The cloud Docker run

The owner opens a claude.ai/code session on `ops-scripts` (no real secrets, fake upstream only).

- [ ] **Step 1:** `tests/run.sh` (every bats file). The new tests from Tasks 1 and 4–7 run for the first time.
- [ ] **Step 2:** Decide `SCRIPTS_ROLE`: if "the scripts' key reads daily activity for every user" fails with `proxy_admin_viewer`, set `proxy_admin` in `setup-keys.sh`, rerun, and record which in `provider-facts.md`. Refresh `tests/fixtures/gateway-*.json` from `tests/.artifacts/gateway-api/` if the shapes differ, with key values replaced.
- [ ] **Step 3:** Fix what fails, test first; rerun until everything passes. Commit and push.
- [ ] **Step 4:** Record the result (files, tests, passed) in `docs/decisions.md` on `phase-0-walkthrough`.

### Task 13: Whole-branch review, then hand over

- [ ] **Step 1:** A fresh reviewer reads the whole branch against the spec, with this plan's Review focus. Fix what it finds, test first.
- [ ] **Step 2:** Push `ops-scripts`. Update `docs/test-procedures/phase-0-status.md` on `phase-0-walkthrough` (what was built, the owner's procedure next) and record the build in `docs/decisions.md`.
- [ ] **Step 3:** Walk the owner through `docs/test-procedures/ops-scripts.md`, one step at a time, recording each result. After it passes: Claude does A11–A13, then the onboarding (`docs/onboarding.md`, the spec's "Onboarding, last"), which is outside this plan.
