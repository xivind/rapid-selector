# Phase 0: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Compose stack (`gateway`, `db`, `chat`) with the allowlist, budgets and keys from the phase 0 spec, its operator scripts, a level 1 test suite against a fake upstream, and the matching changes in the `production` repository.

**Architecture:** Upstream images are configured, never forked. Everything we write is bash (`curl`, `jq`) plus two tiny Python standard-library fakes used only by tests. Tests are bats files that drive the real `docker-compose.yml` and `gateway/config.yaml`, with `tests/compose.test.yml` pointing LiteLLM at the fake upstream.

**Tech Stack:** Docker Compose v2, LiteLLM (`ghcr.io/berriai/litellm-database:v1.106.6`), Postgres (alpine), Open WebUI (`ghcr.io/open-webui/open-webui:v0.13.0`), bash, `curl`, `jq`, bats 1.11.0 (`npx --yes bats@1.11.0`), shellcheck (`uvx --from shellcheck-py shellcheck`), Python 3 standard library.

**Spec:** `docs/superpowers/specs/2026-11-03-phase-0-foundation-design.md`, which follows `docs/superpowers/specs/2026-11-03-rapid-selector-overall-design.md`. Read both, and `CLAUDE.md`.

## Global Constraints

- Branch `claude/ecstatic-hypatia-t1sj0o` in rapid-selector. Commit after each task; every commit message ends with the two attribution lines from the session's system reminder. No model identifiers in commits or files.
- Everything in English. Names prefixed `rapidselector`: Compose project `rapidselector`; containers `rapidselector-db`, `rapidselector-gateway`, `rapidselector-chat`; volumes `rapidselector_pgdata`, `rapidselector_chatdata`.
- Images pinned, never `latest`. LiteLLM `ghcr.io/berriai/litellm-database:v1.106.6`; Open WebUI `ghcr.io/open-webui/open-webui:v0.13.0`; Postgres: the newest `17.x-alpine` patch tag at implementation time, confirmed by `tests/check-arm64.sh`.
- Published ports bound to `${RAPIDSELECTOR_LAN_ADDRESS}`, never `0.0.0.0`: gateway `4000`, chat `4010`. `db` publishes nothing. No custom networks, no `network_mode: host`.
- Limits in USD: LiteLLM global `max_budget: 32`, `budget_duration: 30d`; team `permanent` $8 (`30d`), key `node-red` $4 (`30d`, about 30 requests a minute); team `experiments` $24 (`30d`); key `smoke-test` $1 (`30d`); key `chat` no budget of its own.
- The OpenRouter key variable is `RAPIDSELECTOR_OPENROUTER_KEY`. The string `OPENROUTER_API_KEY` must not appear in `docker-compose.yml`, `gateway/config.yaml` or `.env.example`, and no entry sets `use_in_pass_through`.
- Every model entry: `extra_body.provider` = `{order: [<slug>], only: [<slug>], allow_fallbacks: false, zdr: true, data_collection: deny}`, explicit `input_cost_per_token` and `output_cost_per_token`, and a default `max_tokens`. Values from spec section 3, re-checked against `GET https://openrouter.ai/api/v1/endpoints/zdr` when written; a changed price or a missing endpoint stops the task and goes to the owner.
- Secrets never written to disk by our scripts and never printed. Compose requires each secret with `${NAME:?…}`.
- Nothing in this plan spends real money or touches the owner's network. Levels 2 and 3 are run later with the owner, walked through step by step.
- If a level 1 finding breaks an assumption in the spec (for example LiteLLM drops `extra_body.provider`, or rejects custom key values), stop and report to the owner before continuing.
- Observations (not assertions) are written to `docs/provider-facts.md` with the LiteLLM or Open WebUI version and the date.

## Review Focus

1. **Secret values with shell-special characters** (`$`, quotes, spaces) in `.env` or the secrets-service blob must reach the containers unchanged. Test in Task 2.
2. **secrets-service unreachable or returning 401/423** must make `rapidselector.sh` exit non-zero before Docker is called, with a message that names the cause. Test in Task 2.
3. **A gateway restart mid-month** must keep recorded spend, so an exhausted budget still blocks after `./rapidselector.sh restart gateway`. Test in Task 5.
4. **A client that sets its own large `max_tokens`** is not capped by the default; the behaviour is recorded, and the README tells clients to keep it small. Test in Task 4.
5. **`setup-keys.sh` run against a gateway whose keys were edited in the admin UI** resets budgets, allowed names and rate limits to the script's values. Test in Task 5.

---

## File structure

```
rapidselector.sh                 load settings and secrets, exec docker compose
docker-compose.yml               db, gateway, chat
.env.example                     every variable, explained
.gitignore                       .env, tests/.artifacts/
gateway/config.yaml              allowlist, prices, budgets, settings
scripts/lib.sh                   shared helpers: die, require_env, api (curl wrapper with master key)
scripts/setup-keys.sh            teams and keys
scripts/smoke-test.sh            one call per role or name, refusals, total cost
scripts/drain-balance.sh         test A
tests/run.sh                     start stack with test override, run bats, tear down
tests/compose.test.yml           fake-upstream, fake-secrets, OPENROUTER_API_BASE override, test LAN address
tests/fakes/upstream.py          fake OpenAI-compatible upstream (stdlib only)
tests/fakes/secrets_service.py   fake secrets-service (stdlib only)
tests/fakes/Dockerfile           python:3-alpine image for both fakes
tests/helpers.bash               bats helpers: gw_call, upstream_last_request, upstream_mode, metric
tests/*.bats                     one file per task area
tests/check-arm64.sh             every pinned image has linux/arm64
README.md                        operator guide
docs/test-procedures/phase-0.md  levels 2 and 3, walked through
```

---

### Task 1: Test harness and fakes

**Files:**
- Create: `.gitignore`, `tests/fakes/upstream.py`, `tests/fakes/secrets_service.py`, `tests/fakes/Dockerfile`, `tests/helpers.bash`, `tests/run.sh`, `tests/fakes.bats`

**Interfaces:**
- Produces, fake upstream (port 8000 in its container, service name `fake-upstream`):
  - `POST /v1/chat/completions` → 200, `{"id":"gen-fake-N","model":<request model>,"choices":[{"index":0,"message":{"role":"assistant","content":"fake reply"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":50,"total_tokens":150[,"cost":C]}}`; `cost` included only when mode `cost` is set (C from the mode, default `0.01`).
  - `GET /_requests` → JSON array of every received request: `{"path","headers","body"}`. `DELETE /_requests` clears it.
  - `POST /_mode` with `{"status": 200|402|500, "cost": null|float, "delay_ms": int}` sets behaviour; `402` answers `{"error":{"code":402,"message":"Insufficient credits"}}`.
- Produces, fake secrets-service (port 8002, service `fake-secrets`): `GET /secrets/rapidselector` with `Authorization: Bearer test-token` → `{"name":"rapidselector","blob":{...}}` from the JSON file at `$FAKE_SECRETS_FILE`; wrong token → 401; `POST /_status {"status":423}` forces that status.
- Produces, `tests/helpers.bash`: `upstream_requests` (prints `/_requests` JSON), `upstream_reset`, `upstream_mode <status> [cost] [delay_ms]`, `gw_call <key> <model> [extra_json]` (POST to `http://localhost:${GATEWAY_PORT}/v1/chat/completions`, writes body to `$output`, status to `$GW_STATUS`, response cost header to `$GW_COST`), `metric <name> [label_regex]` (sums matching lines from `/metrics`).
- Produces, `tests/run.sh [bats files…]`: starts the stack with `docker compose -f docker-compose.yml -f tests/compose.test.yml up -d --build --wait`, runs `npx --yes bats@1.11.0` on the given files (default all `tests/*.bats`), always tears down with `down -v`. Uses a generated test `.env` in `tests/.artifacts/` (random secrets, `RAPIDSELECTOR_LAN_ADDRESS=127.0.0.1`), never the real `.env`.

- [ ] **Step 1: Write `tests/fakes.bats`** with tests `fake upstream answers chat completions with usage`, `fake upstream records requests`, `fake upstream switches to 402`, `fake secrets-service returns blob with valid token and 401 otherwise`. They run the two fakes directly (`docker compose -f tests/compose.test.yml up -d fake-upstream fake-secrets`), not the full stack.
- [ ] **Step 2: Run** `npx --yes bats@1.11.0 tests/fakes.bats` — expected FAIL (files missing).
- [ ] **Step 3: Implement** the two fakes with `http.server` and `json` only, the Dockerfile (`python:3-alpine`, pinned to the current 3.x alpine tag), helpers and `run.sh`. Start the Docker daemon first in the cloud sandbox (`dockerd &`) if `docker info` fails; `run.sh` prints that hint.
- [ ] **Step 4: Run** the bats file — expected PASS. Run `uvx --from shellcheck-py shellcheck tests/run.sh tests/helpers.bash` — expected no findings.
- [ ] **Step 5: Commit** `test: add level 1 harness and fakes`.

---

### Task 2: `rapidselector.sh` and `.env.example`

**Files:**
- Create: `rapidselector.sh`, `scripts/lib.sh`, `.env.example`, `tests/rapidselector.bats`

**Interfaces:**
- Produces, `rapidselector.sh <compose args…>`; special command `update` = `docker compose pull` then `docker compose up -d`. Reads `.env` (path overridable by `RAPIDSELECTOR_ENV_FILE`, for tests). `SECRETS_SOURCE` is `env` or `secrets-service`; anything else → exit 2, message `SECRETS_SOURCE must be env or secrets-service`.
- With `secrets-service`: reads the token from `SECRETS_SERVICE_TOKEN_FILE`, `GET ${SECRETS_SERVICE_URL}/secrets/rapidselector`, exports every field in the required list from `.blob`. Missing field → exit 3 naming the field; HTTP 401/423/other or connection failure → exit 4 naming the status. Docker is never called on failure.
- Required secret names (the list lives once, in `scripts/lib.sh` as `RAPIDSELECTOR_SECRETS`): `POSTGRES_PASSWORD LITELLM_MASTER_KEY LITELLM_SALT_KEY LITELLM_UI_PASSWORD RAPIDSELECTOR_OPENROUTER_KEY WEBUI_SECRET_KEY KEY_CHAT KEY_NODE_RED KEY_SMOKE_TEST`.
- Produces, `scripts/lib.sh`: `die <exit_code> <message>`, `require_env <name…>`, `api <method> <path> [json]` (curl to `http://${RAPIDSELECTOR_LAN_ADDRESS}:${GATEWAY_PORT}` with `Authorization: Bearer $LITELLM_MASTER_KEY`, prints body, returns non-zero on HTTP ≥ 400 and prints status to stderr).
- `.env.example`: settings `RAPIDSELECTOR_LAN_ADDRESS`, `GATEWAY_PORT=4000`, `CHAT_PORT=4010`, `SECRETS_SOURCE=env`, `SECRETS_SERVICE_URL=http://home-assistant:8002`, `SECRETS_SERVICE_TOKEN_FILE`; every secret name above, empty, each with a one-line comment and the command that generates it (`openssl rand -hex 32`; virtual keys `echo "sk-$(openssl rand -hex 24)"`; the OpenRouter key from the dashboard). A comment that the salt key must never change after first start.

- [ ] **Step 1: Write `tests/rapidselector.bats`** with a stub `docker` first on `PATH` that writes its arguments and the values of the required secrets to `tests/.artifacts/docker-call`. Tests:
  - `env source passes secrets and arguments to docker compose` (asserts `compose up -d` and each value)
  - `values with $, quotes and spaces arrive unchanged` (Review Focus 1)
  - `secrets-service source exports blob fields` (uses `fake-secrets`)
  - `missing blob field exits 3 and names the field without calling docker`
  - `secrets-service 401 and 423 and unreachable exit 4 without calling docker` (Review Focus 2)
  - `unknown SECRETS_SOURCE exits 2`
  - `update runs pull then up -d`
  - `no secret value is printed to stdout or stderr`
- [ ] **Step 2: Run** `npx --yes bats@1.11.0 tests/rapidselector.bats` — expected FAIL.
- [ ] **Step 3: Implement** `rapidselector.sh`, `scripts/lib.sh` and `.env.example`. Parse `.env` without `source` (read `KEY=VALUE` lines literally) so values are never evaluated by the shell. Use `jq -r --arg k "$name" '.blob[$k] // empty'`.
- [ ] **Step 4: Run** the bats file — expected PASS; shellcheck on both scripts — no findings.
- [ ] **Step 5: Commit** `feat: add rapidselector.sh with env and secrets-service sources`.

---

### Task 3: Compose with `db` and `gateway`

**Files:**
- Create: `docker-compose.yml`, `gateway/config.yaml` (minimal: settings from spec section 3 and the single entry `classify`), `tests/compose.test.yml` (extend from Task 1), `tests/stack.bats`

**Interfaces:**
- Consumes: Task 1 harness, Task 2 secret names.
- Produces: services `db` and `gateway` as in spec section 4: `name: rapidselector`; `container_name` per Global Constraints; restart `unless-stopped`; logging `json-file`, `max-size: 10m`, `max-file: "5"`; memory limits 512m (`db`), 1536m (`gateway`); gateway command `--config /app/config.yaml --port 4000 --num_workers 1`; `DATABASE_URL=postgresql://litellm:${POSTGRES_PASSWORD}@db:5432/litellm`; `UI_USERNAME=admin`, `UI_PASSWORD=${LITELLM_UI_PASSWORD:?…}`; healthchecks `pg_isready -U litellm` and `GET /health/liveliness`; `depends_on: db: condition: service_healthy`.
- Produces, `tests/compose.test.yml`: adds `fake-upstream`, `fake-secrets`; sets `OPENROUTER_API_BASE=http://fake-upstream:8000/v1` on `gateway`.

- [ ] **Step 1: Write `tests/stack.bats`:**
  - `compose refuses to run without a required secret` (`docker compose config` with `LITELLM_MASTER_KEY` unset exits non-zero and names it)
  - `published ports bind to the LAN address only` (`docker compose config --format json` shows `host_ip` = `RAPIDSELECTOR_LAN_ADDRESS` for every published port; `db` has none)
  - `gateway depends on a healthy db` (`depends_on.db.condition` is `service_healthy` in `docker compose config`, and both report healthy)
  - `classify answers through the fake upstream`
  - `the string OPENROUTER_API_KEY appears nowhere in compose, config or .env.example`
  - `no image uses latest or no tag`
- [ ] **Step 2: Run** `tests/run.sh tests/stack.bats` — expected FAIL.
- [ ] **Step 3: Implement** `docker-compose.yml` and the minimal `gateway/config.yaml`.
- [ ] **Step 4: Run** — expected PASS. If the LiteLLM health path differs in v1.106.6, use the documented one and note it in `docs/provider-facts.md`.
- [ ] **Step 5: Commit** `feat: add db and gateway services`.

---

### Task 4: Full allowlist and gateway behaviour

**Files:**
- Modify: `gateway/config.yaml` (all 11 entries and every setting in spec section 3)
- Create: `tests/gateway.bats`, `tests/compose.noprice.yml`, `tests/config.noprice.yaml`
- Modify: `docs/provider-facts.md` (findings)

**Interfaces:**
- Consumes: Task 3 stack; uses the master key for calls in this task (keys come in Task 5).
- Produces: model names exactly as in spec section 3: `classify`, `summarise`, `code`, `chat`, `llama-3.2-1b-instruct@cloudflare`, `llama-3.1-8b-instruct@deepinfra`, `gpt-oss-20b@deepinfra`, `gpt-oss-120b@deepinfra`, `gpt-oss-120b@primeintellect`, `deepseek-v4.1-flash@deepinfra`, `qwen3.8-2.4t-a95b@siliconflow`. `qwen3.8-2.4t-a95b@siliconflow` also sets `reasoning_effort: medium`.

- [ ] **Step 1: Write `tests/gateway.bats`:**
  - `every name answers` (loop over the 11 names)
  - `provider object reaches the upstream unchanged` (for each name, the recorded body has `.provider` equal to the expected object with that entry's slug)
  - `model sent upstream is the pinned openrouter model` (e.g. `chat` → `openai/gpt-oss-120b`)
  - `default max_tokens is applied` (no `max_tokens` from client → recorded body has 1024 for `classify`, 2048 for `summarise`, 8192 for `chat`)
  - `client max_tokens behaviour is recorded` (client sends 50000 to `classify`; the test asserts the call succeeds and writes the forwarded value to `tests/.artifacts/findings.txt`) (Review Focus 4)
  - `a model outside the allowlist is refused` (`openai/gpt-4o` and `openrouter/openai/gpt-oss-120b` → 4xx, nothing reaches the upstream)
  - `openrouter pass-through is refused` (`POST /openrouter/v1/chat/completions` → 4xx, nothing reaches the upstream)
  - `spend is above zero without upstream cost` (mode cost null → `x-litellm-response-cost` > 0 and equals 100 × input price + 50 × output price)
  - `spend source with upstream cost is recorded` (mode cost 0.01 → which value LiteLLM recorded goes to findings)
  - `metrics answer without a key and contain the alert metrics` (`GET /metrics` 200 without auth and without redirect; contains `litellm_spend_metric`, `litellm_proxy_failed_requests_metric`, `litellm_deployment_failure_responses`, `litellm_postgres_failed_requests_total` or its documented equivalent)
  - `zero-cost metric rises when a price is missing` (overlay `tests/compose.noprice.yml` mounts `tests/config.noprice.yaml`, a copy of the config without prices on `classify`; `litellm_zero_cost_requests_total` increases)
- [ ] **Step 2: Run** `tests/run.sh tests/gateway.bats` — expected FAIL for all but `classify`.
- [ ] **Step 3: Implement** the remaining entries and settings. Re-check each price and slug against `https://openrouter.ai/api/v1/endpoints/zdr` first (Global Constraints).
- [ ] **Step 4: Run** — expected PASS. Copy the recorded findings (max_tokens behaviour, spend source, LiteLLM version) into `docs/provider-facts.md` under LiteLLM with date and version. If the provider object is not forwarded unchanged, stop and report (Global Constraints).
- [ ] **Step 5: Commit** `feat: add the starting allowlist and gateway settings`.

---

### Task 5: Teams and keys (`scripts/setup-keys.sh`)

**Files:**
- Create: `scripts/setup-keys.sh`, `tests/keys.bats`, `tests/compose.lowbudget.yml`, `tests/config.lowbudget.yaml`
- Modify: `docs/provider-facts.md` (budget error format, team availability)

**Interfaces:**
- Consumes: `scripts/lib.sh` (`api`, `require_env`, `die`), Task 4 names.
- Produces, `scripts/setup-keys.sh` (no arguments; needs the gateway up; run as `./rapidselector.sh run-script scripts/setup-keys.sh`, defined below):
  - Teams by `team_alias`: `permanent` (`max_budget` from `BUDGET_TEAM_PERMANENT`, default 8; `budget_duration: 30d`; `models`: the four roles) and `experiments` (`BUDGET_TEAM_EXPERIMENTS`, default 24; `30d`; all 11 names).
  - Keys by `key_alias`, value from the secret: `node-red` (team `permanent`, `BUDGET_KEY_NODE_RED` default 4, `30d`, `rpm_limit: 30`, roles only), `chat` (team `experiments`, no budget, all names), `smoke-test` (team `experiments`, `BUDGET_KEY_SMOKE_TEST` default 1, `30d`, all names).
  - Missing → create (`/team/new`, `/key/generate` with `key` set to the secret value). Existing → update (`/team/update`, `/key/update`) to these values.
  - Prints a table: alias, team, budget, duration, allowed names count, rate limit. Never prints key values.
  - The `BUDGET_*` overrides exist for tests only and are documented as such.
- Add to `rapidselector.sh` the command `run-script <path> [args]`: loads settings and secrets exactly as for Compose, then runs the script with them in its environment instead of calling Docker. Test in this task.

- [ ] **Step 1: Write `tests/keys.bats`:**
  - `setup-keys registers our own key values` (each `KEY_*` works as a bearer key afterwards)
  - `second run changes nothing unexpected` (team and key info identical apart from timestamps)
  - `setup-keys restores values edited outside the script` (change `node-red`'s budget and models via `/key/update`, rerun, values restored) (Review Focus 5)
  - `node-red key may use roles only` (`chat` role ok; `gpt-oss-20b@deepinfra` refused)
  - `key budget blocks` (`BUDGET_KEY_SMOKE_TEST=0.03`, mode cost-free pricing: calls until refused; refused within 4 calls; status and body written to findings)
  - `team budget blocks` (`BUDGET_TEAM_PERMANENT=0.03`, calls with `node-red` until refused)
  - `global budget blocks` (overlay `tests/compose.lowbudget.yml` mounts `tests/config.lowbudget.yaml` with `max_budget: 0.05`; calls with `chat` until refused)
  - `spend survives a gateway restart` (exhaust a key, `docker compose restart gateway`, still refused) (Review Focus 3)
  - `run-script passes secrets to the script and not to docker`
- [ ] **Step 2: Run** `tests/run.sh tests/keys.bats` — expected FAIL.
- [ ] **Step 3: Implement** the script and `run-script`. If `/key/generate` rejects a custom `key`, or teams are refused as an Enterprise feature, stop and report (Global Constraints).
- [ ] **Step 4: Run** — expected PASS; shellcheck clean. Record the budget error status, type and message, and team availability, in `docs/provider-facts.md`.
- [ ] **Step 5: Commit** `feat: add setup-keys with teams, keys and budgets`.

---

### Task 6: `chat` (Open WebUI)

**Files:**
- Modify: `docker-compose.yml` (service `chat` per spec section 4)
- Create: `tests/chat.bats`

**Interfaces:**
- Consumes: Task 5 keys (`KEY_CHAT`).
- Produces: service `chat`, container `rapidselector-chat`, `ghcr.io/open-webui/open-webui:v0.13.0`, port `${RAPIDSELECTOR_LAN_ADDRESS}:${CHAT_PORT}:8080`, volume `rapidselector_chatdata:/app/backend/data`, memory 1536m, healthcheck `GET /health`, `depends_on: gateway: condition: service_healthy`, environment exactly as the table in spec section 4 with `OPENAI_API_KEY=${KEY_CHAT:?…}`.

- [ ] **Step 1: Write `tests/chat.bats`** (drives Open WebUI's HTTP API):
  - `first account is created as admin with signup disabled` (`POST /api/v1/auths/signup` on an empty volume → 200, role `admin`)
  - `second signup is refused`
  - `models listed come from the gateway only` (`GET /api/models` with the admin token lists the 11 names and nothing else)
  - `a chat completion goes through the gateway` (recorded upstream request with `chat`'s key traffic; spend on key `chat` > 0)
  - `title generation uses llama-3.1-8b-instruct@deepinfra` (after a chat, a recorded upstream request with `model` = `meta-llama/llama-3.1-8b-instruct`, or a finding if Open WebUI only generates titles from its frontend flow)
  - `no tags, follow-up or autocomplete calls reach the upstream` (after a chat, only the chat call and at most one title call were recorded)
  - `admin panel changes are not persisted` (change a setting through the API, restart `chat`, setting back to its environment value)
- [ ] **Step 2: Run** `tests/run.sh tests/chat.bats` — expected FAIL.
- [ ] **Step 3: Implement** the service. Check each variable name against `https://docs.openwebui.com/reference/env-configuration` for v0.13.0.
- [ ] **Step 4: Run** — expected PASS. Record API paths that differed from the above in `docs/provider-facts.md`.
- [ ] **Step 5: Commit** `feat: add chat service`.

---

### Task 7: `scripts/smoke-test.sh`

**Files:**
- Create: `scripts/smoke-test.sh`, `tests/smoke.bats`

**Interfaces:**
- Consumes: `KEY_SMOKE_TEST`, the 11 names, `scripts/lib.sh`.
- Produces, `scripts/smoke-test.sh [--all]`, run through `./rapidselector.sh run-script`: one call per role (or per name with `--all`), prompt `Reply with the word ok.`, `max_tokens` 256, `reasoning_effort: low` for reasoning entries. Per call prints `name status cost_usd`. Then checks `openai/gpt-4o` and `/openrouter/v1/chat/completions` are refused. Prints `total_usd`. Exit 0 only if every call answered with cost > 0 and both refusals happened; otherwise exit 1 listing failures.

- [ ] **Step 1: Write `tests/smoke.bats`:** `passes against a healthy stack and reports both refusals`, `--all covers 11 names`, `fails when a call returns 500` (upstream mode 500), `fails when recorded cost is zero` (with the no-price overlay from Task 4).
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — expected PASS; shellcheck clean.
- [ ] **Step 5: Commit** `feat: add smoke test`.

---

### Task 8: `scripts/drain-balance.sh`

**Files:**
- Create: `scripts/drain-balance.sh`, `tests/drain.bats`

**Interfaces:**
- Consumes: master key, `scripts/lib.sh`.
- Produces, `scripts/drain-balance.sh --max-usd <amount> [--max-calls N]` (default `--max-calls 500`), run through `./rapidselector.sh run-script`:
  1. Prints what it will do and the limits; requires typing `drain` on stdin, else exit 1 without any call.
  2. Creates key alias `drain-test` in team `experiments`, budget `--max-usd`, `30d`, model `qwen3.8-2.4t-a95b@siliconflow` only.
  3. Calls that model with `max_tokens` 8192 one at a time until the first non-200; stops early when the call count reaches `--max-calls` or LiteLLM's recorded spend for the key reaches `--max-usd`.
  4. If stopped by a refusal: sends 5 parallel calls and records each status.
  5. Prints calls made, recorded spend, the last 3 statuses and bodies, the burst statuses, and the reason it stopped. Deletes `drain-test` on every exit path (trap).

- [ ] **Step 1: Write `tests/drain.bats`:** `refuses to start without typed confirmation`, `stops at the first 402 and sends a burst of 5` (upstream switches to 402 after N calls — add `fail_after` to the fake's `/_mode` in this task), `stops at max-calls`, `stops at max-usd`, `deletes the temporary key on every exit path` (including Ctrl-C simulated with `kill -INT`).
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — expected PASS; shellcheck clean.
- [ ] **Step 5: Commit** `feat: add drain-balance for test A`.

---

### Task 9: Database failure, arm64 and resource checks

**Files:**
- Create: `tests/resilience.bats`, `tests/check-arm64.sh`
- Modify: `docs/provider-facts.md`

**Interfaces:**
- Produces, `tests/check-arm64.sh`: reads every `image:` from `docker-compose.yml` (and the fakes' base image), runs `docker buildx imagetools inspect`, exits 1 naming any image without `linux/arm64`.

- [ ] **Step 1: Write `tests/resilience.bats`:** `behaviour with db stopped is recorded` (stop `db`; a call with `smoke-test`: status and body to findings; the test fails only if the call succeeds with spend not recorded and budgets ignored, which would be fail-open), `gateway recovers when db returns`, `every container has a memory limit and log rotation` (`docker inspect`).
- [ ] **Step 2: Run** `tests/run.sh tests/resilience.bats` and `tests/check-arm64.sh` — expected FAIL (missing script).
- [ ] **Step 3: Implement** `check-arm64.sh`; fix anything the tests reveal. If the gateway serves calls with the database down and budgets ignored, stop and report: the spec assumed the opposite.
- [ ] **Step 4: Run** both — expected PASS. Record the db-failure behaviour in `docs/provider-facts.md`.
- [ ] **Step 5: Commit** `test: add resilience and arm64 checks`.

---

### Task 10: README and the level 2 and 3 procedure

**Files:**
- Create: `README.md` (replace the one-line file), `docs/test-procedures/phase-0.md`
- Modify: `docs/decisions.md` (open questions answered by level 1: 3 in part, 11, 12, 14)

- [ ] **Step 1: Write `README.md`** for someone who has never used Compose: what it is; requirements; first setup (generate secrets, `.env` or secrets-service with the secret `rapidselector` and its fields, `./rapidselector.sh up -d`, `./rapidselector.sh run-script scripts/setup-keys.sh`, Open WebUI admin account); the commands `up -d`, `down`, `logs -f`, `ps`, `update`; addresses and ports table (gateway 4000 with admin UI at `/ui`, login `admin` with `LITELLM_UI_PASSWORD`; chat 4010; 4020 reserved for tower); keys and teams; how a client calls a role (curl example to `http://llm:4000/v1/chat/completions`); client behaviour (fixed timeout, at most one retry on timeout or 5xx, no retry on budget or 402 errors, keep `max_tokens` small); changing Open WebUI settings only through `docker-compose.yml`; backup fallback (`pg_dump` and volume tar commands) and that the salt key must be kept with it; the manual kill switch (OpenRouter dashboard, `./rapidselector.sh stop gateway`); a fixed LAN address (DHCP reservation); developer section (`dockerd`, `tests/run.sh`, `tests/check-arm64.sh`).
- [ ] **Step 2: Write `docs/test-procedures/phase-0.md`** from spec section 8 (A–E), one numbered step per action with: what to run or click, what you should see, what to report back, and the cost of the step. Include the cost ceiling ($1 plus the smallest top-up) and the stop rule.
- [ ] **Step 3: Verify** every command in both files exists in the repository and every port, name and budget matches the spec (`grep` each against `docker-compose.yml`, `gateway/config.yaml`, `scripts/setup-keys.sh`).
- [ ] **Step 4: Update** `docs/decisions.md` with the level 1 answers, citing `docs/provider-facts.md`.
- [ ] **Step 5: Commit** `docs: add README and phase 0 test procedure`.

---

### Task 11: Changes in the `production` repository

Needs write access to `xivind/production` (request with `add_repo`, access `push`) or the owner's local session. Follow that repository's `CLAUDE.md` and `backup-orchestrator/CLAUDE.md`; work on a branch there and let the owner merge.

**Files (in `production`):**
- Modify: `prometheus/prometheus.yml` (job `rapidselector-gateway`, target `sandbox:4000`)
- Modify: `backup-orchestrator/backup-run.sh` (new check `pg-dump`: last line `-- PostgreSQL database dump complete`), `backup-orchestrator/jobs.conf` (two jobs, `min_bytes` placeholder `1` with a comment to set it after the first run), `backup-orchestrator/CLAUDE.md` and `README.md` (jobs table; "Backup missing" `< 11`)
- Create: `backup-orchestrator/jobs/rapidselector-postgres.sh`, `backup-orchestrator/jobs/rapidselector-chat.sh`, `backup-orchestrator/remote/rapidselector-export.sh` (forced command on `sandbox`: argument `postgres` → `docker exec rapidselector-db pg_dump -U litellm litellm`; argument `chat` → stop `rapidselector-chat`, tar its volume to stdout with `--log-driver none`, start it again on every exit path)
- Create/Modify: bats tests in `backup-orchestrator/tests/` for the `pg-dump` check and the two jobs, matching the existing style
- Modify: `nodered/create-container-nodered.sh` (`--add-host="llm:192.168.1.212"`, sandbox's address from the same file)
- Create: `grafana/rapidselector-alerts.md`: the seven rules from spec section 7 with exact PromQL using the label names recorded at level 1, thresholds, `for` durations, folder **Alerts**, group **rapid-selector**, for the owner's local session to create through the Grafana MCP

- [ ] **Step 1: Write the bats tests** for the `pg-dump` check (valid dump passes; truncated dump fails) and the two jobs (stubbed `ssh`).
- [ ] **Step 2: Run** `npx --yes bats@1.11.0 backup-orchestrator/tests` — expected FAIL for the new tests.
- [ ] **Step 3: Implement** the check, jobs, remote script and config changes; write `grafana/rapidselector-alerts.md`.
- [ ] **Step 4: Run** the full bats suite and `uvx --from shellcheck-py shellcheck -x backup-orchestrator/*.sh backup-orchestrator/jobs/*.sh backup-orchestrator/remote/*.sh` — expected PASS and no findings.
- [ ] **Step 5: Commit** on the branch in `production`, and tell the owner what needs a manual step (Prometheus restart, installing the forced-command key on `sandbox`, Node-RED restart, creating the alerts from a local session, the `llm` router alias).

---

After Task 11, phase 0 is code-complete but **not yet verified**. The owner and Claude then run `docs/test-procedures/phase-0.md` together (spec section 8), and the results go in `docs/decisions.md`.
