# Phase 0: Foundation

Date: 2026-11-03. Status: approved by the owner on 2026-11-03.

Follows the overall design (`2026-11-03-rapid-selector-overall-design.md`) and the rules in `CLAUDE.md`. Facts about LiteLLM, Open WebUI and OpenRouter used here were checked in their documentation and OpenRouter's public API on 2026-11-03 and are recorded in `docs/provider-facts.md`.

## 1. Scope

### Delivered in rapid-selector

| File | Contents |
|---|---|
| `docker-compose.yml` | `gateway`, `db` and `chat`: pinned images, ports bound to the LAN address, memory limits, healthchecks, volumes, log rotation, required secrets |
| `gateway/config.yaml` | Allowlist, roles, prices, default `max_tokens`, budgets, retention, metrics |
| `.env.example` | Every variable with an explanation; nothing secret |
| `rapidselector.sh` | Loads secrets (`.env` or secrets-service), then runs Compose |
| `scripts/setup-keys.sh` | Creates teams and registers virtual keys through LiteLLM's API; safe to run again |
| `scripts/smoke-test.sh` | One cheap call per role (or per name with `--all`); spend above zero; refusals checked |
| `scripts/drain-balance.sh` | Test A: uses up a small balance and stops at the first refusal |
| `tests/` | Level 1: the stack against a fake upstream, and bats tests of the scripts |
| `README.md` | Setup, the commands, addresses and ports, keys, client behaviour, backup fallback, manual kill switch |
| `docs/test-procedures/phase-0.md` | Levels 2 and 3, step by step |

### Delivered in the `production` repository
A Prometheus scrape target, Grafana alert rules, backup jobs for Postgres and Open WebUI, and Node-RED's host entry for `llm` (section 7).

### Not in phase 0
Tower, the Grafana dashboard, container logs to Loki, web search in Open WebUI, and the move to `webserver`.

## 2. Decisions

| Topic | Decision |
|---|---|
| Currency | USD for every limit |
| OpenRouter inference key | Monthly limit $34 (set to $0.05 during test B) |
| LiteLLM global budget | $32 a month |
| Team `permanent` | $8 a month: Node-RED and later apps; roles only |
| Team `experiments` | $24 a month: chat, the smoke test, the drain test, later the arena |
| Budget windows | `30d`, which LiteLLM resets on the 1st of the month at 00:00 UTC, in step with OpenRouter |
| Prepaid balance | One month's top-up at a time |
| Free models | None (`CLAUDE.md`, principle 1) |
| Ports | Gateway 4000, `chat` 4010, tower 4020 (reserved) |
| Open WebUI background calls | Titles on, using `llama-3.1-8b-instruct@deepinfra`; tags, follow-ups, autocomplete, search and retrieval query generation off |
| Web search | Off; parked in `docs/roadmap.md` |
| Container logs | Not shipped to Loki; rotated locally |
| `/metrics` | No authentication (`require_auth_for_metrics_endpoint: false`), like `node_exporter` |
| Alert rules | Created through the Grafana MCP from a local Claude Code session |
| Real-money tests | B, then the spend and host checks, then A, at the first top-up; ceiling $1 plus the smallest top-up |

## 3. Gateway (`gateway/config.yaml`)

### Model entries
Each entry pins one OpenRouter endpoint, including its quantisation, and leaves OpenRouter no other choice:

```yaml
- model_name: chat
  litellm_params:
    model: openrouter/openai/gpt-oss-120b
    api_key: os.environ/RAPIDSELECTOR_OPENROUTER_KEY
    max_tokens: 8192
    input_cost_per_token: 0.000000037
    output_cost_per_token: 0.00000017
    extra_body:
      provider:
        order: ["deepinfra/bf16"]
        only: ["deepinfra/bf16"]
        allow_fallbacks: false
        zdr: true
        data_collection: deny
```

- The OpenRouter key is read from `RAPIDSELECTOR_OPENROUTER_KEY`, never `OPENROUTER_API_KEY`, and no entry sets `use_in_pass_through`. LiteLLM's `/openrouter/…` pass-through takes its key from one of those two, and its calls "record $0 spend, so budgets do not count them".
- Added 2026-11-03 after inspecting the v1.106.6 image: with no key found, the pass-through still forwards the request (with `Bearer None`). So every virtual key also gets `allowed_routes` limited to chat completions and the model list, and the route is refused before anything leaves the house.
- Every entry carries `model_info: {rapidselector_kind: role|experiment, reasoning: true|false}`. This file is the only list of names: the scripts read names, kinds and reasoning flags from the gateway's `/model/info`.
- A role and an experiment name for the same model are two entries with the same pin and price.
- Prices are the pinned endpoint's, from OpenRouter's API on 2026-11-03, and are checked again when the file is written.

### Starting set (11 entries)

Prices per million tokens, input / output.

**Roles:**

| Name | Model | Endpoint | Price | Reasons | Default `max_tokens` |
|---|---|---|---|---|---|
| `classify` | `mistralai/mistral-small-3.2-24b-instruct` | `deepinfra/fp8` | $0.075 / $0.20 | No | 1024 |
| `summarise` | `google/gemma-4-26b-a4b-it` | `coreweave/bf16` | $0.10 / $0.30 | Optional, off by default | 2048 |
| `code` | `qwen/qwen3-coder-30b-a3b-instruct` | `siliconflow/fp8` | $0.07 / $0.28 | No | 8192 |
| `chat` | `openai/gpt-oss-120b` | `deepinfra/bf16` | $0.037 / $0.17 | Yes | 8192 |

**Experiment names:**

| Name | Endpoint | Price | Reasons | Default `max_tokens` |
|---|---|---|---|---|
| `llama-3.2-1b-instruct@cloudflare` | `cloudflare` | $0.027 / $0.201 | No | 2048 |
| `llama-3.1-8b-instruct@deepinfra` | `deepinfra/fp8` | $0.02 / $0.04 | No | 2048 |
| `gpt-oss-20b@deepinfra` | `deepinfra/bf16` | $0.03 / $0.14 | Yes | 8192 |
| `gpt-oss-120b@deepinfra` | `deepinfra/bf16` | $0.037 / $0.17 | Yes | 8192 |
| `gpt-oss-120b@primeintellect` | `primeintellect/fp4` | $0.03 / $0.11 | Yes | 8192 |
| `deepseek-v4.1-flash@deepinfra` | `deepinfra/fp8` | $0.14 / $0.42 | Yes | 8192 |
| `qwen3.8-2.4t-a95b@siliconflow` | `siliconflow/fp8` | $2.00 / $6.00 | Yes, default effort `xhigh`; set to `medium` | 8192 |

- Every endpoint is on OpenRouter's list of zero data retention endpoints (`GET /api/v1/endpoints/zdr`), and none is in the "flex" service tier.
- With `qwen3.8-2.4t-a95b` at `medium` effort, one call costs at most about 8,192 × $6/M ≈ $0.05 in output.
- The roles are a starting point, to be changed when the arena gives data.

### Settings

| Setting | Value |
|---|---|
| `litellm_settings.max_budget` / `budget_duration` | 32 / `30d` |
| `litellm_settings.callbacks` | `["prometheus"]` |
| `litellm_settings.require_auth_for_metrics_endpoint` | `false` |
| `general_settings.store_model_in_db` | `false` |
| `general_settings.maximum_spend_logs_retention_period` | `"90d"` |
| `general_settings.master_key`, `database_url` | From the environment |

### Teams and keys
Created by `scripts/setup-keys.sh`, which holds the budgets, allowed names and rate limits, so they are in git.

| Team or key | Budget (monthly) | May use | Note |
|---|---|---|---|
| Team `permanent` | $8 | Roles | |
| Key `node-red` | $4 | Roles | Rate limit about 30 calls a minute |
| Team `experiments` | $24 | All names | |
| Key `chat` | None of its own | All names | |
| Key `smoke-test` | $1 | All names | Smoke test and level 3 |

- The key values are generated in advance and stored as secrets (`KEY_CHAT`, `KEY_NODE_RED`, `KEY_SMOKE_TEST`). `setup-keys.sh` registers them with exactly those values, so `chat`'s key exists before `chat` starts, and keys survive a rebuild or a move.
- Running the script again creates what is missing and resets budgets, allowed names and rate limits to its values.

## 4. Compose and the services

Common: Compose project `rapidselector`; restart policy `unless-stopped`; logging `json-file` with `max-size: 10m` and `max-file: 5`; published ports bound to `${RAPIDSELECTOR_LAN_ADDRESS}`.

| | `db` | `gateway` | `chat` |
|---|---|---|---|
| Container | `rapidselector-db` | `rapidselector-gateway` | `rapidselector-chat` |
| Image | `postgres:17.11-alpine` | `ghcr.io/berriai/litellm-database:v1.106.6` | `ghcr.io/open-webui/open-webui:v0.13.0` |
| Port | None | `LAN:4000 → 4000` | `LAN:4010 → 8080` |
| Storage | Volume `rapidselector_pgdata` | `./gateway/config.yaml`, read-only | Volume `rapidselector_chatdata` |
| Memory limit (initial) | 512 MB | 1.5 GB | 1.5 GB |
| Healthcheck | `pg_isready` | LiteLLM's health endpoint | `/health` |
| Starts after | – | `db` healthy | `gateway` healthy |

- The gateway runs one worker (`--num_workers 1`) and sets `LITELLM_LOCAL_MODEL_COST_MAP=True`, so it does not fetch LiteLLM's price map from GitHub at every start.
- LiteLLM's admin UI logs in with `UI_USERNAME=admin` and `UI_PASSWORD` from the secret `LITELLM_UI_PASSWORD`.
- The memory limits are measured and adjusted at level 2.
- All three pinned images were confirmed for `linux/arm64` on 2026-11-03.

### Open WebUI settings
Set as environment variables, with `ENABLE_PERSISTENT_CONFIG=False` so the admin panel cannot save changes:

| Setting | Value |
|---|---|
| `OPENAI_API_BASE_URL` / `OPENAI_API_KEY` | `http://gateway:4000/v1` / `chat`'s virtual key |
| `ENABLE_OLLAMA_API`, `ENABLE_DIRECT_CONNECTIONS` | `False` |
| `ENABLE_SIGNUP` | `False` |
| `ENABLE_TITLE_GENERATION` / `TASK_MODEL_EXTERNAL` | `True` / `llama-3.1-8b-instruct@deepinfra` |
| `ENABLE_TAGS_GENERATION`, `ENABLE_FOLLOW_UP_GENERATION`, `ENABLE_AUTOCOMPLETE_GENERATION`, `ENABLE_SEARCH_QUERY_GENERATION`, `ENABLE_RETRIEVAL_QUERY_GENERATION` | `False` |
| `ENABLE_WEB_SEARCH`, `ENABLE_IMAGE_GENERATION`, `ENABLE_EVALUATION_ARENA_MODELS` | `False` |
| `BYPASS_EMBEDDING_AND_RETRIEVAL` | `True` |
| `WEBUI_SECRET_KEY` | From the secrets |

### Variables (`.env.example`)
- **Settings:** `RAPIDSELECTOR_LAN_ADDRESS`, `GATEWAY_PORT=4000`, `CHAT_PORT=4010`, `SECRETS_SOURCE=env` (or `secrets-service`), `SECRETS_SERVICE_URL`, and the path to the secrets-service token file.
- **Secrets:** `POSTGRES_PASSWORD`, `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `LITELLM_UI_PASSWORD`, `RAPIDSELECTOR_OPENROUTER_KEY`, `WEBUI_SECRET_KEY`, `KEY_CHAT`, `KEY_NODE_RED`, `KEY_SMOKE_TEST`. The README gives a command to generate each.

## 5. Scripts

All bash with `curl` and `jq`, tested with bats and checked with shellcheck.

### `rapidselector.sh <command>`
- Reads the non-secret settings from `.env`.
- With `SECRETS_SOURCE=secrets-service`: reads the client token from its file, fetches the one secret `rapidselector` (a blob holding every secret field), and fails loudly on a missing field (the `// empty` check in the `production` repository's `secrets-service/CLAUDE.md`).
- Exports the values and runs `docker compose "$@"`. `update` runs `pull` then `up -d`. `run-script <path>` runs one of our scripts with the same settings and secrets instead of Compose.
- Writes nothing secret to disk.

### `scripts/setup-keys.sh`
- Uses the master key. Creates the teams and registers the keys (section 3), and ends with a summary of each team and key.

### `scripts/smoke-test.sh [--all]`
- Uses `KEY_SMOKE_TEST`. One tiny call per role, or per name with `--all`; reasoning models get low effort and room for a short answer.
- Checks for each call that an answer came back and that the recorded cost (`x-litellm-response-cost`) is above zero.
- Checks that a model outside the allowlist and `/openrouter/…` are refused.
- Reports the total cost.

### `scripts/drain-balance.sh`
Test A, run only while the owner is walked through it:
1. Asks for a typed confirmation.
2. Creates a temporary key `drain-test` in team `experiments`, with a budget above the balance.
3. Calls `qwen3.8-2.4t-a95b@siliconflow` one at a time until the first refusal, then sends 5 calls in parallel.
4. Hard stops: a maximum number of calls, and a maximum total entered by the owner (the top-up plus $1).
5. Prints the number of calls, LiteLLM's recorded cost and the last answers, then deletes the temporary key.

The owner reads the balance in OpenRouter's dashboard.

## 6. Level 1 tests

### Setup
- `tests/compose.test.yml` adds a fake upstream and sets `OPENROUTER_API_BASE` to it. Everything else is the real `docker-compose.yml` and `gateway/config.yaml`.
- **Fake upstream:** a Python program using only the standard library, in its own container. It answers `/v1/chat/completions` with fixed text and known `usage`, with or without OpenRouter's `cost` field; records every request; and can be switched to answer 402 or 5xx.
- **Fake secrets-service:** the same kind of program, serving `GET /secrets/rapidselector`.
- **Tests:** bats with `curl` and `jq`. Each test file starts the stack it needs and tears it down; `tests/run.sh` runs them all and is the regression suite after any change. In the cloud sandbox the Docker daemon is started first (`dockerd`). Level 1 does not run on a host where rapid-selector is running, because container names and ports are fixed.
- LiteLLM writes spend in batches (every 10 seconds by default), so budget tests allow and record a small overshoot.

### What is checked

| Area | Checks |
|---|---|
| Routing | Every name answers; `extra_body.provider` reaches the upstream unchanged |
| Refusals | A model outside the allowlist; `/openrouter/…`; the `node-red` key using an experiment name |
| `max_tokens` | The default is applied when the client sets none; the behaviour when the client sets its own is recorded |
| Spend | Recorded above zero; whether LiteLLM uses OpenRouter's `cost` or the configured price; `litellm_zero_cost_requests_total` rises when a price is missing |
| Budgets | Key, team and global budgets block when used up (small test budgets); the error code and type are recorded |
| Start-up safety | Compose refuses to run without secrets; the gateway waits for `db`; behaviour when `db` stops while running is recorded |
| Metrics | `/metrics` answers without a key, without a redirect, and contains the metrics the alerts use |
| Keys | Custom key values are accepted; a second run of `setup-keys.sh` changes nothing unexpected |
| Open WebUI | The first account can be created with `ENABLE_SIGNUP=False` and a second is refused; chat goes through the gateway; titles use `llama-3.1-8b-instruct@deepinfra`; no calls for tags, follow-ups or autocomplete reach the upstream |
| Scripts | `rapidselector.sh` with both sources, including a missing field; `smoke-test.sh`; `drain-balance.sh` stops at the first 402, sends its burst and keeps to its hard limits |
| arm64 | `tests/check-arm64.sh` confirms `linux/arm64` for every pinned image |
| Prices | `tests/check-prices.sh` compares every entry's price, endpoint and tier with OpenRouter's public API. Free; run before every change to the allowlist |

What is observed rather than asserted is recorded in `docs/provider-facts.md` with the version and date. If a finding breaks an assumption in this spec, work stops and the owner is consulted.

## 7. Changes in the `production` repository

Made following that repository's conventions. This session has read access only; write access is requested when the work starts, or the changes are made from the owner's local session.

### Prometheus
A scrape job in `prometheus/prometheus.yml`, then a restart of the `prometheus` container:

```yaml
  - job_name: 'rapidselector-gateway'
    static_configs:
    - targets: ['sandbox:4000']
```

### Grafana alert rules
In folder **Alerts**, new group **rapid-selector**, through the default notification policy. The exact queries are fixed in the plan from the label names seen at level 1.

| Rule | Intent | For |
|---|---|---|
| Team budget below 20% | Remaining / max team budget < 0.2, for each of `permanent` and `experiments` | 15 min |
| Team budget below 10% | The same, < 0.1 | 15 min |
| Failure rate on roles | Failed / all calls on the four roles > 20%, with a minimum number of calls | 15 min |
| Gateway down | `up{job="rapidselector-gateway"} == 0` | 5 min |
| Recorded at $0 | `litellm_zero_cost_requests_total` rose in the last hour | Immediately |
| Database failing | `litellm_postgres_failed_requests_total` rose | 5 min |
| Many 401s | More than 10 calls refused with 401 in 15 minutes | Immediately |

No rule for the global budget: the team budgets add up to it exactly.

### Backup jobs (`backup-orchestrator`)

| Job | How | Check |
|---|---|---|
| `rapidselector-postgres` | SSH to `sandbox` with a forced command that runs `pg_dump` in `rapidselector-db` to stdout, following the Node-RED job | New check `pg-dump`: last line `-- PostgreSQL database dump complete`, with bats tests |
| `rapidselector-chat` | SSH with a forced command that stops `rapidselector-chat`, tars its volume and starts it again | `tar` |

- `min_bytes` is set after the first run, to about half the size.
- "Backup missing" goes from `< 9` to `< 11`.
- `chat` is down for a few seconds during the nightly run.

### Node-RED and the router
- `nodered/create-container-nodered.sh` gets `--add-host="llm:<sandbox's address>"`, then Node-RED is restarted. The `--dns` fix stays a separate item (`docs/decisions.md`, open question 19).
- The owner creates the alias `llm` → `sandbox` on the router.

## 8. First setup, levels 2 and 3

Written in `docs/test-procedures/phase-0.md`. Claude walks the owner through every step; the owner reports what they saw, and Claude records the results in `docs/decisions.md`.

### A. OpenRouter preparation (dashboard)
1. Auto top-up off. Prompt logging and every data collection opt-in off. Zero data retention on for the account, if offered.
2. Create the gateway's inference key, with a monthly limit of $0.05 for test B.
3. Buy the smallest top-up.

### B. Level 2 on `sandbox`
1. Clone the repository, generate the secrets, store them as the secret `rapidselector` in secrets-service, place the token file, fill in `.env`.
2. `./rapidselector.sh up`: all three healthy. Run `scripts/setup-keys.sh`.
3. Create the admin account at `sandbox:4010`.
4. Measure memory with `docker stats`; Claude adjusts the limits in a commit.
5. `scripts/smoke-test.sh`: the four roles, under $0.01.

### C. `production` repository
The Prometheus target, the alert rules, the backup jobs, Node-RED's host entry and the `llm` alias (section 7). Done before level 3, so warnings are live during it. The budget alerts are expected to fire during test A.

### D. Level 3, at most $1 plus the smallest top-up
1. **Test B:** call until 402 with the key limit at $0.05; record how far past the limit the last call went; set the limit to $34.
2. **Spend:** `scripts/smoke-test.sh --all`, all 11 entries; compare each call's cost in LiteLLM and in OpenRouter's activity log.
3. **Hosts:** the activity log shows the host for each call; all must match the pins.
4. **Zero data retention, negative:** a temporary, uncommitted entry pinned to an endpoint without zero data retention must be refused.
5. **Test A:** `scripts/drain-balance.sh`; read the balance.
6. The regular top-up.

### E. Backups and first real use
1. After the first nightly backup, a restore rehearsal on `sandbox` into a separate Compose project; an existing key must still work.
2. A Node-RED flow calls `classify` at `llm:4000` with the `node-red` key and gets an answer.

## 9. Done when

- Level 1 passes in the cloud sandbox.
- Sections 8 A to E are completed, with results in `docs/decisions.md`. This answers open questions 1, 2, 3, 5 and 7, and level 1 answers 11, 12 and 14.
- Every alert rule exists, and the backup jobs have run once without errors.

Until then, phase 0 is reported as not yet verified.
