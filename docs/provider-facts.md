# Provider facts

Dated observations about providers, models, prices and tool behaviour. These change quickly: check against the current documentation before relying on them, and add a new dated entry rather than silently editing an old one.

## OpenRouter

### From the owner's research, 2026-11-02
- Broker: requests are served by upstream hosts such as DeepInfra.
- A 5.5% fee is charged when buying credits.
- The docs list a 402 error when the balance cannot cover a request, but also mention negative balances.
- Prompts and responses are not logged by default, but metadata such as token counts and timestamps is stored. An opt-in to prompt logging gives a 1% discount.
- `GET /api/v1/key` returns the key's limit, remaining limit and usage. `GET /api/v1/credits` returns total credits and total usage, and requires the management key.
- Kill switch: `PATCH /api/v1/keys/{hash}` with `disabled: true` disables a key.
- The `X-OpenRouter-Metadata: enabled` header reports which host served a request.
- Catalog price and host price can differ: `gpt-oss-120b` was listed at $0.15/$0.60 per million tokens (in/out), while DeepInfra charged $0.037/$0.17.

### Checked in the docs, 2026-11-03
Sources: https://openrouter.ai/docs/api-reference/limits and https://openrouter.ai/docs/features/provisioning-api-keys
- **Key limit resets:** a key's credit limit can reset daily, weekly or monthly ("optional daily/weekly/monthly limit resets"), or never. Spend windows are UTC: a monthly one resets on the first of the month at 00:00 UTC.
- **Errors:** a key whose limit is exhausted gets 402. 403 is for organisation and workspace guardrail budgets, which a personal account does not use.
- **Negative balance:** "If your account has a negative credit balance, you may see […] errors, including for free models." (The error code is missing from the fetched page text.) How far below zero a balance can go is not stated.
- **In-flight spending budget:** OpenRouter estimates each paid request's cost up front (input tokens plus `max_tokens`, or a fixed cap when `max_tokens` is not set) and holds it against the balance while the request runs. A request that does not fit is rejected before it reaches a host, with `limit_source` in the error's metadata.
- **Management keys:** "cannot be used to make API calls to OpenRouter's completion endpoints". A leaked one "could create, edit and delete the API keys in your account". OpenRouter recommends an expiry date on every management key; the expiry cannot be changed after creation, and an expired key gets `401 API key expired`.

## LiteLLM

### 2026-11-02 (owner) and 2026-11-03 (checked)
- LiteLLM's price map (`model_prices_and_context_window.json` on the `main` branch) has no `openrouter/` entries: 0 of 4,561 entries on 2026-11-03. OpenRouter models therefore need explicit prices in the gateway config, or spend is recorded at 0.

### Checked in the docs, 2026-11-03
Sources: https://docs.litellm.ai/docs/proxy/users, https://docs.litellm.ai/docs/providers/openrouter, https://docs.litellm.ai/docs/proxy/prometheus, https://docs.litellm.ai/docs/proxy/configs, https://docs.litellm.ai/docs/proxy/custom_pricing
- **Budget windows:** `budget_duration` takes seconds, minutes, hours or days (e.g. `30d`). Corrected the same day: https://docs.litellm.ai/docs/proxy/budget_reset_and_tz says `30d` "Resets on the 1st of each month at midnight", `7d` on Monday and `1d` daily, in the configured `timezone` (UTC by default). So a `30d` budget lines up with OpenRouter's monthly reset.
- **Budgets need the database.** Without one, `litellm_settings.max_budget` "fails open": the global budget check is skipped and requests keep being served. Key, team and user budgets are unavailable.
- **OpenRouter's reported cost:** "OpenRouter provides cost information in the response, which LiteLLM automatically tracks." The detailed text found (from v1.104.3, spend is the `usage.cost` OpenRouter returns) is about OpenRouter's Decisions endpoint; whether it holds for chat calls is unconfirmed. The same page says calls through the `/openrouter` pass-through to other paths "record $0 spend, so budgets do not count them".
- **Prometheus metrics** at `/metrics`, including `litellm_spend_metric`, `litellm_remaining_api_key_budget_metric`, `litellm_remaining_team_budget_metric` and `litellm_deployment_failure_responses`. The page marks only managed batch metrics as "Enterprise only".
- **Public model names:** in `config.yaml`, `model_name` is the name clients use, and `litellm_params.model` is the underlying model. This is how roles are made.
- **Custom pricing:** `input_cost_per_token` and `output_cost_per_token` can be set per model.
- **`/openrouter` pass-through:** sends requests to OpenRouter as they are, using the key of the first OpenRouter entry with `use_in_pass_through: true`, "or from `OPENROUTER_API_KEY` when no deployment does". Calls to paths other than the Decisions API "are forwarded but record $0 spend, so budgets do not count them".
- **`/metrics` authentication:** "From v1.85.0, /metrics requires LiteLLM API key authentication by default." Turned off with `litellm_settings.require_auth_for_metrics_endpoint: false`.
- **More metrics:** `litellm_zero_cost_requests_total` ("Requests that carried usage but were logged at $0 on a model whose pricing entry has a non-zero rate"), `litellm_postgres_failed_requests_total`, `litellm_proxy_failed_requests_metric`.
- **Spend log retention is free:** "Retention and cleanup are open source." Set with `general_settings.maximum_spend_logs_retention_period` (e.g. `"7d"`). Source: https://docs.litellm.ai/docs/proxy/spend_logs_deletion
- **Budget error** (example in the docs): `"type": "budget_exceeded"`, `"code": "400"`. Another example returns `"detail": "Authentication Error, ExceededTokenBudget: …"`.
- **OpenRouter provider parameters:** LiteLLM's OpenRouter page documents only `transforms`, `models` and `route`. Whether `extra_body.provider` is forwarded unchanged is tested at level 1.
- **Images:** `ghcr.io/berriai/litellm-database:v1.106.6` is the newest plain release tag found, and is published for `linux/amd64` and `linux/arm64`. The `main-v…-stable` tags stop at `v1.83.14`.

### Seen in the v1.106.6 image, 2026-11-03
Inspected in `ghcr.io/berriai/litellm-database:v1.106.6` (package version 1.106.6).
- `GenerateKeyRequest` has the fields `key`, `key_alias`, `team_id`, `rpm_limit`, `budget_duration` and `allowed_routes`, so key values can be chosen by us.
- Health routes `/health/liveliness`, `/health/liveness` and `/health/readiness` exist.
- `UI_USERNAME` is read in `proxy/auth/login_utils.py`.
- `require_auth_for_metrics_endpoint` is honoured in `proxy/middleware/prometheus_auth_middleware.py`.
- Chat calls to OpenRouter use `OPENROUTER_API_BASE` when set (`main.py`), which the level 1 fake upstream relies on.
- `extra_body` is popped from the parameters and merged into the request body (`llms/openrouter/chat/transformation.py`).
- The `/openrouter/{endpoint}` route takes its key from `passthrough_endpoint_router.get_credentials(custom_llm_provider="openrouter")` and sends `Authorization: Bearer {key}` even when none is found (`proxy/pass_through_endpoints/llm_passthrough_endpoints.py`).
- Key-level `allowed_routes` is checked in `proxy/auth/route_checks.py` without a licence check; the licence check there applies to `general_settings.admin_only_routes`.
- In `team_endpoints.py`, the premium checks seen apply to team admins and per-model team budgets, not to creating teams.
- At start it fetches `model_prices_and_context_window.json` from GitHub unless `LITELLM_LOCAL_MODEL_COST_MAP=True`.
- Spend is written to the database in batches: `PROXY_BATCH_WRITE_AT`, default 10 seconds.
- `postgres:17-alpine` was 17.11 on this date; `postgres:17.11-alpine` is published for `linux/arm64`.

### Level 1 findings, v1.106.6, 2026-11-03
From `tests/gateway.bats` against the fake upstream.
- **Spend source:** when OpenRouter's response carries `usage.cost`, LiteLLM records that cost (`x-litellm-response-cost` = 0.01 for a fake cost of 0.01, where the configured price would give 0.0000175). Without it, LiteLLM uses the configured price (100 × input + 50 × output price, exactly). Streamed calls are recorded too.
- **`extra_body.provider` is forwarded unchanged** for all 11 entries, and `reasoning_effort: medium` reaches OpenRouter as `reasoning_effort`.
- **Default `max_tokens` is only a default:** a client that sends 50000 gets 50000 forwarded.
- **Names outside the allowlist** (`openai/gpt-4o`, `openrouter/openai/gpt-4o`, `openrouter/anthropic/claude-3.5-sonnet`, `deepinfra/…`) are refused with 400 and nothing reaches OpenRouter. An underlying model string that matches an entry (`openrouter/openai/gpt-oss-120b`) is routed to that entry, with its pin and price.
- **`/openrouter/…` pass-through with the master key** forwards the request with `Authorization: Bearer None` (confirmed). Virtual keys are limited by `allowed_routes` (Task 5).
- **`/metrics` redirects (307) to `/metrics/`.** Prometheus should scrape `/metrics/`.
- **Postgres and spend-writer metrics** (`litellm_postgres_*`) appear only with `litellm_settings.service_callback: ["prometheus_system"]`.
- **`litellm_zero_cost_requests_total`** counts only calls whose price entry declares a positive rate but whose cost came out as 0 (`litellm_core_utils/llm_cost_calc/zero_cost_diagnostic.py`). A model with no price at all is treated as free and not counted, and one with only an input price records the input cost. So it does not catch a missing price; `tests/gateway.bats` checks that every entry records cost above zero instead.

- **Budgets block with HTTP 422** (not the 400 in the docs' example): `{"error":{"message":"Budget has been exceeded! Key=smoke-test (sk-...) Current cost: 0.040015, Max budget: 0.03","type":"budget_exceeded","code":"422"}}`; for a team the message names `Team=permanent`. Clients must treat 422 `budget_exceeded` like 402: no retry.
- **Overshoot:** key and team budgets let through at most one call past the limit (the check runs before the call, against spend written in batches every 10 seconds). The global budget overshot more: 5 calls of about $0.02 against $0.05, with 12 seconds between calls. It is checked against a separate proxy-wide total in the database (`fetch_global_spend_with_event_coordination` in `user_api_key_auth.py`). Since the team budgets add up to the global budget, they are what stops spend promptly.
- **Teams work in the open-source version** (`/team/new`, `/team/update`, team budgets), and **custom key values are accepted** by `/key/generate`.
- **`allowed_routes` is necessary:** without it, a virtual key that names a model it may use (e.g. `classify`) gets HTTP 200 from `/openrouter/v1/chat/completions`, and the request goes out with `Bearer None`. With it, the route is refused (401/403).
- Budgets come back as floats (`1.0`).

- **The database stopping fails closed:** with Postgres stopped, a key whose budget is used up is still refused (422, from LiteLLM's cache), and a key not in the cache gets `503` "Service Unavailable, the authentication database is temporarily unreachable". When Postgres returns, calls work again within seconds, without restarting the gateway.

- **Metric labels seen on a running gateway:** team budgets as `litellm_remaining_team_budget_metric` and `litellm_team_max_budget_metric` with labels `team` and `team_alias`; `litellm_deployment_failure_responses_total` and `litellm_deployment_total_requests_total` with `requested_model` and `model_group` (the role name); `litellm_proxy_failed_requests_metric_total` with `exception_status` (e.g. `401` for an unknown key, `500`). The exact alert queries are in the `production` repository, `grafana/rapidselector-alerts.md`.
- **About 8 failed Postgres queries at every start:** `litellm_postgres_failed_requests_total{error_class="RawQueryError",function_name="query_raw"}` is 8 after start and stays there with traffic (142 → 167 total queries, still 8 failed). Nothing about them appears in the log.
- **The admin UI** is at `/ui`, which redirects to `/ui/`.

## Open WebUI

### Checked in the docs, 2026-11-03
Source: https://docs.openwebui.com/reference/env-configuration
- Settings can be given as environment variables, among them `ENABLE_SIGNUP`, `ENABLE_OLLAMA_API`, `ENABLE_DIRECT_CONNECTIONS`, `ENABLE_TITLE_GENERATION`, `ENABLE_TAGS_GENERATION`, `ENABLE_FOLLOW_UP_GENERATION`, `ENABLE_AUTOCOMPLETE_GENERATION`, `ENABLE_SEARCH_QUERY_GENERATION`, `ENABLE_RETRIEVAL_QUERY_GENERATION`, `TASK_MODEL_EXTERNAL`, `ENABLE_WEB_SEARCH`, `ENABLE_IMAGE_GENERATION`, `ENABLE_EVALUATION_ARENA_MODELS`, `BYPASS_EMBEDDING_AND_RETRIEVAL`.
- With `ENABLE_PERSISTENT_CONFIG` set to `False`, settings can still be edited in the admin UI, but "these changes are NOT saved".
- `ghcr.io/open-webui/open-webui:v0.13.0` is published for `linux/amd64` and `linux/arm64`.

### Level 1 findings, v0.13.0, 2026-11-03
From `tests/chat.bats` against the gateway and the fake upstream.
- With `ENABLE_SIGNUP=False`, the first account can still be created on an empty volume and becomes admin; a second signup is refused.
- The model list shown is exactly the gateway's 11 names.
- Title, tags, follow-up, autocomplete and query generation are separate API calls (`/api/v1/tasks/<name>/completions`) made by the browser. With our settings, only the title call reaches the gateway, and it uses `TASK_MODEL_EXTERNAL` (`llama-3.1-8b-instruct@deepinfra`) whatever model the chat uses. With `ENABLE_FOLLOW_UP_GENERATION=True`, a follow-up call reaches the gateway (checked).
- With `ENABLE_PERSISTENT_CONFIG=False`, a setting changed through the admin API (`ENABLE_SIGNUP`) takes effect until restart, then returns to the environment's value.
- With `BYPASS_EMBEDDING_AND_RETRIEVAL=True`, it downloads no embedding model at start, and uses about 634 MiB of memory after start (amd64, cloud sandbox).
- The image has `curl`, used for its healthcheck (`/health`).

## OpenRouter catalogue

### Price changes seen, 2026-11-03 and 2026-11-04
- `openai/gpt-oss-120b` at `primeintellect/fp4` had three prices within a day: $0.03 / $0.11, then $0.035 / $0.13, then $0.026 / $0.095 per million tokens. `tests/check-prices.sh` caught the last change. The other ten pinned endpoints kept their prices.

### From OpenRouter's API, 2026-11-03
Sources: `GET https://openrouter.ai/api/v1/models` (453 models) and `GET https://openrouter.ai/api/v1/endpoints/zdr` (1,090 zero data retention endpoints).
- 141 open-weight models (with a Hugging Face id) have at least one paid zero data retention endpoint.
- 14 models end in `:free`. Only one free text model has a zero data retention endpoint (`xingchen-agi/xing4.0-29b-a4b:free` at Phala).
- `meta-llama/llama-3.2-1b-instruct` has a zero data retention endpoint at Cloudflare ($0.027 / $0.201 per million tokens).
- Endpoints are addressed by slugs that include the variant, e.g. `deepinfra/fp8` or `deepinfra/turbo` (https://openrouter.ai/docs/guides/routing/provider-selection). Routing fields include `order`, `only`, `allow_fallbacks`, `zdr`, `data_collection` and `quantizations`.
- Reasoning defaults: `gpt-oss-120b` and `gpt-oss-20b` reason always (default effort `medium`); `deepseek-v4.1-flash` by default (effort `high`); `qwen3.8-2.4t-a95b` always (default effort `xhigh`); `gemma-4-26b-a4b-it` optionally, off by default.
- Prices for the phase 0 starting set are in `superpowers/specs/2026-11-03-phase-0-foundation-design.md`.

## Docker in the cloud sandbox

### 2026-11-03
- Docker 29.9.2 and Compose v5.6.1 are installed. The daemon is not running at session start; started by hand with `dockerd`, it runs containers (`hello-world` confirmed). The sandbox is `x86_64`.

## Model range

### 2026-11-02 (owner)
All sizes are reached through OpenRouter.
- **Smallest:** `llama-3.2-1b-instruct` (1B, served by Cloudflare), then a 1.8B translation model. General-purpose choices stay scarce until 3B.
- **Largest:** `qwen3.8-2.4t-a95b` (2.4T).
- **Same model on several hosts:** `gpt-oss-120b` has over 20, so hosts can be compared directly.
- **Zero data retention:** `lfm-2.5-2.6b` had no zero data retention host listed.
