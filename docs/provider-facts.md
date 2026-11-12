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
- **Management keys, where they are made (checked 2026-11-07, https://openrouter.ai/docs/guides/overview/auth/management-api-keys):** the dashboard's Management API Keys page, `https://openrouter.ai/settings/management-keys`, then "Create New Key": "Enter a name and choose an expiration". The value is shown once ("You will not be able to see it again"). The page names no limit field for the management key itself; `limit` and `limit_reset` belong to the keys it creates.
- **Management keys:** "cannot be used to make API calls to OpenRouter's completion endpoints". A leaked one "could create, edit and delete the API keys in your account". OpenRouter recommends an expiry date on every management key; the expiry cannot be changed after creation, and an expired key gets `401 API key expired`.

### Checked in the docs, 2026-11-04
Sources: https://openrouter.ai/docs/api-reference/limits and https://openrouter.ai/docs/api-reference/errors. The fetched text has blanks where some status codes belong; the codes below come from the pages' JSON examples and lists.
- **In-flight spending budget:** "a fraction of your current credit balance, up to a fixed ceiling". The fraction, the ceiling and the fixed cap used when `max_tokens` is not set are not published.
- **Who is subject to it:** prepaid accounts whose balance is below a threshold (not published) and, during the rollout, newer accounts without a spending history. A balance at or above the threshold is exempt. So what a small balance on a new account shows may not hold for a larger one.
- **In-flight refusals, 402:** `"reason": "in_flight_budget_exhausted"` with `"limit_source": "openrouter_in_flight_budget"` is temporary, "can occur with no request still running", and has a `Retry-After` header. `"reason": "weight_exceeds_budget"` with `"limit_source": "openrouter_credits"` means one request's estimate is larger than the whole budget, and retrying will not help: lower `max_tokens` or add credits.
- **`limit_source` on a 402:** `openrouter_in_flight_budget`, `openrouter_key_limit` ("the API key's credit limit is exhausted") or `openrouter_credits`.
- **The docs give both 402 and 403 for a spent key limit.** "Handling 402 errors" lists `openrouter_key_limit`, while the budget section says "the key's own limit" gets a 403 before reaching a provider, with `"scope": "key_limit"`. Level 3 shows which one is real. This qualifies the 2026-11-03 entry above.
- Whether in-flight holds count against a key's `limit_remaining` is not stated. Holds are described only against the account's balance.

### Key limits in practice, 2026-11-05
Source: D1 (`decisions.md`, "Tested in practice"), a new account with a $5 balance.
- A spent key limit is refused with **403**, not 402: `"limit_source": "openrouter_key_limit"`, `"scope": "key_limit"`, and `limit_usd`, `spend_usd` and `resets_at` in the metadata. This settles the conflict in the 2026-11-04 entry above, for this account.
- The limit is checked against spend already counted. Five calls at once, then five more, then five more, on a $0.05 limit: all 15 were answered and charged in full, $0.0932, and the next call afterwards was refused. The delay was not measured.
- `GET /api/v1/key` with the key itself showed `limit`, `limit_reset`, `limit_remaining` (0 when spent, not negative), `usage`, `usage_daily`, `usage_weekly`, `usage_monthly`, and `budgets` and `effective_budget`, where `remaining_usd` was negative (−0.0432). No prompt is sent, and no charge was seen.

### Management API, checked in the docs 2026-11-05
Sources: https://openrouter.ai/docs/guides/overview/auth/management-api-keys, https://openrouter.ai/docs/api/api-reference/api-keys/get-a-single-api-key.md, .../update-an-api-key.md, .../list-api-keys.md, https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits.md, https://openrouter.ai/docs/api/api-reference/analytics/get-user-activity-grouped-by-endpoint.md. Not yet tried.
- **One key:** `GET /api/v1/keys/{hash}` with the management key gives `limit`, `limit_remaining`, `limit_reset`, `usage`, `usage_daily`, `usage_weekly` (UTC, Monday to Sunday), `usage_monthly`, `disabled`, `expires_at`, `last_used_at` and a masked `label`. `hash` is not the key itself. `GET /api/v1/keys` lists keys (`include_disabled`, `include_expired`). Answers question 18.
- **Disable and enable:** `PATCH /api/v1/keys/{hash}` with `{"disabled": true}` or `{"disabled": false}`. The docs do not say how quickly it takes effect.
- **Balance:** `GET /api/v1/credits`, management key only, gives `total_credits` and `total_usage`; the balance is the difference, which the page does not spell out.
- **Usage per model:** `GET /api/v1/activity`, management key only: one row per day, model and endpoint, with `provider_name`, `requests`, tokens and `usage` in USD, for the last 30 completed UTC days, so not today. Filter with `api_key_hash`.
- **Account settings:** no endpoint for zero data retention, allowed providers, data training or auto top-up. `/api/v1/organization/settings` exists, but has only a model-catalog filter and returns 404 for a personal account.
- **Expiry:** fixed at creation and cannot be changed; afterwards every request gets `401` "API key expired". A non-management key on these routes gets 403 "Only management keys can perform this operation".
- **Disabled keys in the list, checked in the docs 2026-11-06** (https://openrouter.ai/docs/api/api-reference/api-keys/list-api-keys.md): `GET /api/v1/keys` takes `include_disabled` and `include_expired`. Expired keys are "excluded by default"; for disabled keys no default is written, but the example value is `false`, so a disabled key is assumed to be left out unless `include_disabled=true` is sent. The level 1 fake does the same. The list has no pagination metadata (`offset` only).
- **A disabled key on a chat call, checked in the docs 2026-11-06** (https://openrouter.ai/docs/api-reference/errors): "401: Invalid credentials (OAuth session expired, disabled/invalid API key)". The exact body for a disabled key is not documented; the level 1 fake answers `{"error": {"code": 401, "message": "Invalid credentials"}}`.
- **After level 2, the gateway cools down, tried at level 1 on LiteLLM v1.106.6, 2026-11-06** (level 1 tests since removed; fake upstream): a call that gets the upstream's 401 puts the model group in LiteLLM's cooldown. For about 5 seconds after the key is enabled again, calls get `429` "No deployments available for selected model ... All deployments for selected model are in cooldown", then `200`. No cooldown setting is in `config/gateway.yaml`, so this is LiteLLM's default.
- **`/api/v1/activity`'s `provider_name` is the full endpoint tag, seen live on 2026-11-07** (the real account): `siliconflow/fp8`, `deepinfra/bf16`, `coreweave/fp4`, the same form as `provider.order` in `config/gateway.yaml`, not a display name. `model` is the OpenRouter model id without `openrouter/` (e.g. `openai/gpt-oss-120b`). A test sample that guessed a display name (`"DeepInfra"`) caused a bug.

### Low balance and latency, 2026-11-08
Source: the owner, then https://openrouter.ai/docs/features/latency-and-performance (credit balance section).
- OpenRouter makes extra database checks when the balance is low ("single digit dollars") or a key is near its credit limit, and expires caches more aggressively, which adds latency until credits are added. Its suggested fix, auto top-up with a higher threshold, is ruled out here (`CLAUDE.md`, principle 1). No exact threshold is given beyond "single digit", so `status.sh` warns below $10 (`scripts/jq/status.jq`). Speed measured in these conditions is not comparable.

### Dashboard and settings, checked in the docs 2026-11-10
For `docs/onboarding.md`; read through a fetch helper. The dashboard's own pages need a sign-in, so their layout is checked in the walkthrough, not here. Sources: https://openrouter.ai/docs/faq, `/docs/guides/overview/auth/management-api-keys.md`, `/docs/guides/privacy/data-collection.md`, `/docs/guides/features/zdr.md`, `/docs/guides/routing/provider-selection.md`.
- **Credits:** topped up by hand or by auto top-up below a threshold. A refund can be asked for within 24 hours of a purchase, from `/settings/credits`. "We reserve the right to expire unused credits after one year of purchase", another reason to keep the balance small.
- **Activity:** usage can be filtered "by model, provider and api key".
- **Two places for logging and training:** the privacy settings hold "OpenRouter Use of Inputs/Outputs", off by default, which gives "a 1% discount on all model usage" when on; and a separate **"Private Input & Output Logging"**, off by default, now lives under Observability (`/workspaces/default/observability`). The FAQ ties the discount to a prompt-logging opt-in at `/settings/preferences`; the pages disagree, so both places are checked in the walkthrough. Checked 2026-11-11 by the owner: `/settings/preferences` has no such opt-in; both switches are where the privacy guide says. On `/settings/privacy` the section is now "Data Training", four switches: "Allow paid endpoints that train on request data", "Allow free endpoints that train on request data", "Allow free endpoints that publish prompts", and "Allow 1% data discount in workspaces" ("Allow workspaces to consent to OpenRouter using your inputs/outputs to improve the product. Each workspace consents separately."). The first three steer routing, "separate from Zero Data Retention". Two-factor authentication is at Account, User, Security.
- **Zero data retention** is set per model group at `/settings/privacy` (Anthropic, OpenAI, Google, SpaceXAI, All other models). The account-wide allowed-provider list "acts as a ceiling"; a request no provider satisfies fails with 404.
- **Management keys** are listed at `/settings/management-keys`; the expiry is fixed at creation, and the docs recommend setting one. Expired keys stay listed until deleted.
- **Two-factor authentication:** not found in the docs read. Account deletion is under Settings, Manage Account, Security, the likely place.
- **Workspaces, 2026-11-11** (https://openrouter.ai/docs/guides/features/workspaces, and the owner's dashboard): "Every API key lives in a workspace", and inference keys are listed under Workspace in the menu. Privacy settings and allowed providers are account-level, a ceiling on every workspace. The guide says nothing on renaming; the owner renamed the Default workspace, and the address still starts with `default` and carries an id. Deleting the Default workspace is permanent and "immediately disables every unscoped inference API key on the account".
- **Routers, 2026-11-11** (https://openrouter.ai/docs/guides/routing/routers/overview.md, `/auto-router`, `/jev-router.md`, `/docs/guides/community/jev.md`, and `GET /api/v1/models`): "A model router picks which model handles each request"; then OpenRouter chooses among the providers hosting it. A router acts only when a call sends its slug as the `model` (`openrouter/auto`, `openrouter/auto-code`, `typesafe/jev-router`), or an author alias such as `<author>/auto` where one exists. "Routers don't add a routing fee", and the pool stays within zero data retention requirements and provider restrictions. The catalogue gives routers price `-1`, no fixed price. Jev (`typesafe/jev-1.14`, TypeSafe) is a decision model, not an LLM: it answers typed questions with probabilities and writes no free text. The docs read do not say whether Jev Router's decision is billed on top of the chosen model.

### Credit purchase, 2026-11-04
Sources: the owner's first top-up, and https://openrouter.ai/pricing.
- **$5.00 of credit cost $7.25** from Norway, and the balance showed exactly $5.00. The breakdown was not read from the receipt. ($5 + $0.80) × 1.25 gives exactly $7.25, while 5.5% and 25% VAT alone would give $6.59, so a minimum fee of about $0.80 is likely. The pricing page does not state one.
- The pricing page: "OpenRouter's fee is charged when you buy credits, 5.5% on Standard and 8% on Business, never on individual requests". "Prices are exclusive of applicable taxes. Where required, VAT/GST may be added on invoices." "Standard and Business have no minimums and no lock-in."

### Safety Retention, checked 2026-11-04
Sources: https://openrouter.ai/docs/guides/features/zdr, `GET /api/v1/endpoints/zdr` and the account's settings page.
- **Safety Retention is not zero data retention:** "OpenRouter or a provider may retain prompts and responses from any request, whether flagged or not, only to detect, investigate, and prevent abuse." Not used for training.
- **`provider.zdr: true` depends on the account:** "the request will only be routed to ZDR endpoints, plus Safety Retention endpoints if your settings allow them", and "self-serve accounts allow Safety Retention and enterprise accounts use ZDR only". So zero data retention needs `ZDR only` in the account's settings, under "All other models" and "Google".
- **The public list includes those endpoints,** marked `safety_retention: true`. All 11 pinned endpoints had `false` on this date. `scripts/check-prices.sh` now fails on `true`.
- **Zero data retention has an exception:** "no routine storage of prompts or responses after processing, apart from the CSAM exception described on this page". The page also mentions a planned change dated 2026-10-27, not checked further.
- **Not stated:** whether Gemma on CoreWeave counts as a Google model in the account setting. The account's eligibility count stayed at 121 models after choosing `ZDR only`; each model was not looked up by name.

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
- **`extra_body.provider` is forwarded unchanged** for all 11 entries, and `reasoning_effort: medium` reaches OpenRouter as `reasoning_effort`. But a client could change it: an `extra_body` in the request body replaced the whole pinned provider object (zero data retention included), and `models`, `route` and `transforms` were passed on to OpenRouter (`models` is OpenRouter's fallback list). A top-level `provider` did not get through. `gateway/request_guard.py`, a LiteLLM pre-call callback, now removes all of these, and `tests/keys.bats` checks it (found by the final review, 2026-11-04).
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
- **Spend and tokens per name, checked on the live `/metrics`, 2026-11-09 (v1.106.6, the real gateway):** `litellm_spend_metric_total` and `litellm_input_tokens_metric_total`, `litellm_output_tokens_metric_total` and `litellm_total_tokens_metric_total` carry **no `model_group`**. They carry `requested_model` (the name the client asked for, such as `chat` or `llama-3.1-8b-instruct@deepinfra`) and `model` (the model id underneath, such as `openai/gpt-oss-120b`), with `api_key_alias`, `team_alias` and `service_tier`. Wherever both labels exist (`litellm_deployment_*`, the latency histograms), `requested_model` equals `model_group` for every name, so names that share a model id stay apart either way. LiteLLM's admin UI merges them (Usage). A refused call to a name the key may not use shows as `requested_model="other"`.
- **A team's budget metric appears only after the team's first call:** `litellm_remaining_team_budget_metric` had only `experiments` on 2026-11-09; `permanent`, without a call yet, had never had a series. The same holds after every gateway restart, 2026-11-11: the series is missing until that team's next call, so a firing budget alert resolves at a restart and fires again after the next call.
- **The counters only exist once something happens, and start again from 0 when the gateway restarts:** every new combination of labels (name, key, client, `service_tier`) is a new series, whose first value is the first call itself. Prometheus's `increase()` leaves that first value out and extrapolates instead, so at rapid-selector's traffic it undercounts badly: over 16 hours on 2026-11-09 it saw 1 of 6 answered calls and $0 of $0.000032. The owner's Grafana dashboard counts by adding up every 30-second rise instead (`sum_over_time(clamp_min(((X - X offset 30s) or X), 0)[range:30s])`), which matched OpenRouter's November usage to the millionth ($5.192699); the details are in `production`'s `grafana/rapidselector-dashboard.md`.
- **About 8 failed Postgres queries at every start:** `litellm_postgres_failed_requests_total{error_class="RawQueryError",function_name="query_raw"}` is 8 after start and stays there with traffic (142 → 167 total queries, still 8 failed). Nothing about them appears in the log. *Level 1 only, on a fresh database.* **Not seen on the real gateway, 2026-11-06:** Prometheus has never stored `litellm_postgres_failed_requests_total` from the real gateway since 2026-10-30, not even after the reboot at C5, while `litellm_postgres_total_requests_total` started again at 26. So the series appears only once a query has failed, and the 8 were probably from the fresh test database (unverified).
- **The admin UI** is at `/ui`, which redirects to `/ui/`.

### How v1.106.6 passes on OpenRouter's refusals, 2026-11-04
Against a fake upstream sending the documented bodies. `tests/drain.bats` covers 402 and 403 through the real config; the rest was seen once, without a database or `request_guard`.
- **Status and message are passed on:** 402, 403, 404, 429 and 503 keep their status, and `limit_source` and `reason` stay readable inside `error.message`, as escaped JSON.
- **`Retry-After` is dropped,** on 402 and on 429.
- **Retries:** 403, 429 and 503 reach the upstream 3 times for each client call; 402 and 404 once.
- **Default request timeout:** 6000 seconds (`DEFAULT_REQUEST_TIMEOUT_SECONDS`, `litellm/__init__.py`), not 600.
- **`/model/info` with the master key** has the price at `.model_info.output_cost_per_token`.

### Spend reports, roles and blocking, checked in the docs 2026-11-05
Sources: https://docs.litellm.ai/docs/proxy/cost_tracking, .../virtual_keys, .../access_control, .../users. https://docs.litellm.ai/docs/proxy/enterprise returned 404, so the Enterprise list was not seen. Not yet tried on v1.106.6.
- **Free, by the pages' labels:** `/spend/logs` and `/spend/logs/v2` (per request, the latter paginated), `/user/daily/activity` (per day, broken down by model, provider and API key), `/key/info`, `/team/info`, `/user/info`, `/spend/keys`. A banner lists "spend tracking" among Enterprise features, which the pages do not reconcile with this.
- **Enterprise:** `/global/spend/report`. Team-admin roles and delegated permissions, including `/team/daily/activity` for team members, are "Premium".
- **Blocking:** `POST /key/block` and `/key/unblock` with `{"key": ...}`, one key at a time, not labelled Enterprise. No call blocks a team or all keys at once on these pages.
- **Admin rights without the master key:** a key owned by a user with role `proxy_admin` can call admin routes, and `allowed_routes` can narrow it; `proxy_admin_viewer` sees all keys and spend but "cannot … make any changes", so presumably not block. Not labelled Enterprise. Bears on question 17.

### The admin UI's session key, tried at level 1 on LiteLLM v1.106.6, 2026-11-06
Source: level 1 tests since removed ("LiteLLM's admin UI while level 1 is engaged"), fake upstream, nothing spent.
- Logging in to `/ui` as `admin` (`POST /login`) creates a virtual key with no alias, `user_id` `default_user_id`, `team_id` `litellm-dashboard`, `max_budget` 1.0, no model list (all models), expiring after 24 hours. The `token` cookie is a JWT that carries the key.
- That key is **not** returned by `/key/list`, neither to the master key nor to the admin key the tests used, so blocking every key `/key/list` shows does not block it. After 70 seconds at level 1 it is still unblocked, the UI's own calls with it answer 200, and a model call with it reaches the upstream (200 from the fake). Level 2 still stops it, since every call goes through the one OpenRouter key. For the owner to decide.

### The admin UI, checked in the docs 2026-11-10
For `docs/onboarding.md`; read through a fetch helper, not yet seen on v1.106.6 except where the walkthrough confirms it. Sources: https://docs.litellm.ai/docs/proxy/ui, `/proxy/ui_logs`, `/proxy/customer_usage`, `/proxy/access_control`, `/proxy/model_management`, `/proxy/virtual_keys`.
- **Login:** `UI_USERNAME` (default `admin`) and `UI_PASSWORD`. `general_settings.disable_env_credential_login: true` then refuses both and the master key (401); only database users, created as proxy admins under Internal Users, Invite User, can sign in. Turning it on before such a user exists locks the UI. More than 10 failed logins from one source in 60 seconds block it for 5 minutes. Not marked Enterprise. Bears on finding 41.
- **Logs: metadata only by default** ("By default LiteLLM does not track the request and response content"). Content is stored with `store_prompts_in_spend_logs: true`, **or from the UI, Logs, Settings, "Store Prompts in Spend Logs"**, which "takes effect immediately and overrides config". Our `config.yaml` does not declare the setting, so the UI's switch would work: one click would put chat contents into Postgres and its backups (principle 4). A setting declared in `config.yaml` is "owned by the file", and the UI then refuses to change it (400).
- **Models:** models from `config.yaml` carry a `config` badge and "cannot be edited or deleted from the UI". With `store_model_in_db` declared in the file, the UI's toggle for it answers 400.
- **Usage:** a global view for proxy admins and proxy admin viewers. Whether it groups by public name or by model id is not said; our source reading (2026-11-07, above) says names sharing a model id are merged.
- **Enterprise or Premium:** organizations, team and organization roles, team admins and member permissions, and key rotation. Not marked: usage, virtual keys (block and unblock), models, logs.
- **In v1.106.6 itself, read in the wheel from PyPI on 2026-11-10:** the switch is not on the Logs page but in **Admin Settings, "Logging Settings"** ("Store Prompts in Spend Logs", with "Save Settings"); the owner found it there, off. The server applies a saved value for every new call, unless the file declares the setting: `_apply_boolean_settings` in `proxy_server.py` skips any key `owned_by_config` (the same for `disable_auto_add_proxy_admin_to_teams` and `apply_user_budget_to_team_keys`). So `store_prompts_in_spend_logs: false` in `config.yaml` makes the switch inert (decided 2026-11-10).

### Models through the API, checked in the docs 2026-11-05
Sources: https://docs.litellm.ai/docs/proxy/model_management, .../configs, .../prod. Not yet tried on v1.106.6; nothing on these pages is marked Enterprise.
- `POST /model/new`, `PATCH /model/{model_id}/update` (litellm_params or model_info) and `POST /model/delete` with `{"id": ...}` need `store_model_in_db: true`; otherwise `/model/new` fails. Models are stored in Postgres (`LiteLLM_ProxyModelTable`), survive restarts, and apply to new requests at once.
- Custom `model_info` fields "pass straight through to `GET /model/info`". The pages do not show `extra_body`/`provider`, `max_tokens` or the per-token prices in an API body.
- **Two sources of truth:** models in `config.yaml` keep working alongside, cannot be edited from the UI, and a database model with the same name "becomes an additional deployment that gets load balanced with it". So a pinned name must exist in one place only.
- Stored provider credentials are encrypted with `LITELLM_SALT_KEY`.
- `/config/update` writes `general_settings`, `router_settings` and `litellm_settings` keys into `LiteLLM_Config`; keys declared in `config.yaml` are locked (400).
- With the database down, "the master key and models defined in the config file keep working"; management endpoints fail.

### The scripts' routes, v1.106.6, 2026-11-06
From `tests/gateway-api.bats` (level 1, against the fake upstream). On 2026-11-06 it ran with an earlier admin key (role `proxy_admin`), no team, no budget, and a wider `allowed_routes` than the scripts' key has now. Since 2026-11-08 it runs with the scripts' key (user `scripts`, `SCRIPTS_ROLE` and `SCRIPTS_ROUTES` in `scripts/setup-keys.sh`). Saved responses, with key values and hashes replaced, are in `tests/fixtures/gateway-*.json`.
- **A `proxy_admin` key with `allowed_routes` works for admin routes,** without a licence. Outside its list, LiteLLM answers 403 "Virtual key is not allowed to call this route" (the message lists the allowed routes; no secret). Refused: `/openrouter/v1/chat/completions`, `/v1/chat/completions`, `POST /model/new`, `/key/delete`, `/key/generate`, `/key/update`, `/user/new`, `GET /spend/logs`.
- **`allowed_routes` also matches by prefix:** an entry `/a/b` admits `/a/b` and anything under `/a/b/` (`_route_matches_allowed_route` in `proxy/auth/route_checks.py`). So `/global/spend` also admits `/global/spend/report`, `/global/spend/tags` and `/global/spend/reset`; the last is refused anyway with 401 "only for MASTER KEY".
- **`proxy_admin_viewer` is enough for the scripts' key, 2026-11-08** (level 1, `tests/gateway-api.bats` and `tests/keys.bats`, LiteLLM v1.106.6, fake upstream). With `allowed_routes` set to the three read routes, a key owned by a `proxy_admin_viewer` user reads `/user/daily/activity` with every key's spend (the smoke-test and chat keys' calls both appear), `/team/info` and `/global/spend`, and is still refused on write routes and model calls. So `SCRIPTS_ROLE` in `scripts/setup-keys.sh` stays `proxy_admin_viewer`. The response shapes matched the saved fixtures, so they were not refreshed.
- **`/user/new` creates a key by default,** unrestricted, with the user's role. `auto_create_key: false` creates the user only; `setup-keys.sh` sends it.
- **Token hash:** the `token` LiteLLM stores and lists for a key is the SHA-256 of the key value, as lowercase hex. `GET /key/info` without a `key` parameter describes the calling key, with its hash in `.key`.
- **`GET /model/info`:** `.data[]` with `model_name`, `litellm_params` (`model`, `max_tokens`, `input_cost_per_token`, `output_cost_per_token`, `extra_body.provider` with the pin, `reasoning_effort` where set) and `model_info` (`id`, the prices again, and our own `rapidselector_kind` and `reasoning`). No `api_key` field at all.
- **`GET /key/list?return_full_object=true`:** `{"keys": [...], "total_count", "current_page", "total_pages"}`; every key, with `token` (hash), `key_alias`, `team_id`, `user_id`, `blocked`, budgets and `allowed_routes`. `blocked` is `null` until a key has been blocked once, then `true`, and `false` after unblocking. `key_name` is a masked value (`sk-...` and the last 4 characters).
- **`POST /key/block` and `/key/unblock`** with `{"key": "<hash>"}` answer 200 with the key's row. A call with a blocked key gets 401 `auth_error` "Key is blocked", and nothing reaches the upstream; after unblocking, the next call answers 200.
- **Spend per name, key and day: `GET /user/daily/activity?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD`.** `results[]` per `date`, with `breakdown.model_groups[<name as the client called it>].metrics` (`spend`, `prompt_tokens`, `completion_tokens`, `successful_requests`, `failed_requests`, `api_requests`) and `.api_key_breakdown[<hash>]` with the same metrics and `metadata.key_alias` and `team_id`. Also `breakdown.models` (the underlying OpenRouter model), `api_keys`, `providers` and `endpoints`. For a `proxy_admin` it covers every key. Spend matches `x-litellm-response-cost` per call. Refused calls count under `failed_requests` with no spend. It is written in batches, like key spend.
- **`/spend/logs` does not give it per name for a period:** with `start_date` and `end_date` it returns, per day, spend by key hash and by underlying model only (`{"<hash>": …, "models": {…}, "users": {…}, "spend", "startTime"}`). Without dates it returns every request (with `model_group` and `metadata.user_api_key_alias`), unbounded. The scripts do not use it, and their key may not call it.
- **`GET /team/info?team_id=…`:** `.team_info` with `max_budget`, `budget_duration`, `budget_reset_at` (e.g. `2026-12-01T00:00:00Z`), `spend`, `blocked`, `models`; also `.keys`. **`GET /key/info?key=<hash or value>`:** `.key` (the hash) and `.info` with `key_alias`, `max_budget`, `budget_duration`, `budget_reset_at`, `spend`.
- **Global budget:** `GET /global/spend` gives `{"spend", "max_budget": 32.0}`, the live values; the window (`budget_duration`) is not shown by any route found. `GET /config/field/info?field_name=maximum_spend_logs_retention_period` gives `{"field_value": "90d", "source": "config", "editable": false}`; `field_name=budget_duration` is refused (400, invalid field). So the global budget's window can only be read from `config/gateway.yaml`.
- **The daily table merges names sharing a model id, read in the source of v1.106.6, 2026-11-07** (the wheel from PyPI): `LiteLLM_DailyUserSpend`, which `/user/daily/activity` reads, is unique on user, date, key, model, provider, MCP tool and endpoint, and the in-memory queue that fills it is keyed the same way (`db_spend_update_writer.py`). `model_group`, the public name, is stored but is not part of either key. So names that share an OpenRouter model id (`chat`, `gpt-oss-120b@deepinfra` and `gpt-oss-120b@coreweave` are all `openai/gpt-oss-120b`) are merged into one row, under one of their names, whenever the same key calls more than one of them on a day. Totals, budgets, the per-key figures and `breakdown.models` (per model id) are right; per name or per host is not possible from this table. LiteLLM's admin UI usage view reads the same table and has the same limit. The team table has the same key; `LiteLLM_DailyGlobalSpend` includes `model_group`, but no endpoint in v1.106.6 reads it; `/spend/logs/v2` (paginated, at most 1,000 rows a page) keeps `model_group` per call. No upstream issue was found.

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
- With `BYPASS_EMBEDDING_AND_RETRIEVAL=True`, the standard image still loads its bundled embedding model at every start (2026-11-06 below).
- The image has `curl`, used for its healthcheck (`/health`).

### Checked in the source, v0.13.0, 2026-11-06
Sources: `Dockerfile`, `backend/open_webui/main.py`, `env.py`, `config.py`, `retrieval/utils.py`, `routers/retrieval.py`, `routers/audio/__init__.py` and `routers/evaluations.py` at tag `v0.13.0` on GitHub; image indexes on `ghcr.io`.
- The standard image bundles models in `/app/backend/data/cache`, at build time: the embedding model (`sentence-transformers/all-MiniLM-L6-v2`), `TaylorAI/bge-micro-v2` (the arena leaderboard's), Whisper `base` and a tiktoken encoding. A named volume mounted there gets a copy of them when it is first created. Seen on a Pi: 1.1 GB of `cache/` in the first chat backup.
- At every start, `main.py` calls `get_ef`, which loads the embedding model whenever the embedding engine is the default (empty), whatever `BYPASS_EMBEDDING_AND_RETRIEVAL` says. `RAG_EMBEDDING_MODEL_AUTO_UPDATE` defaults to `True`, so `snapshot_download` checks Hugging Face and fetches the model's whole repository.
- Whisper is loaded on the first speech-to-text request, not at start. If it is not in the cache, it is downloaded even when auto-update is off.
- `OFFLINE_MODE=True` sets `HF_HUB_OFFLINE=1` and turns off all three auto-updates. A missing model then gives an error in the log, and start-up carries on.
- **The slim image** (`v0.13.0-slim`, built with `USE_SLIM=true`, which sets `USE_SLIM_DOCKER=true`) bundles no models, installs `requirements-slim.txt` without torch, and leaves out `git`, `pandoc`, `ffmpeg` and the build tools, but keeps `curl` and `jq`. In its code, `USE_SLIM` skips the local embedding model, the leaderboard's model and local Whisper (speech-to-text needs an outside engine, so a 503). tiktoken is not bundled; it is used to split documents in retrieval, and would be fetched into `cache/tiktoken` the first time.
- `ghcr.io/open-webui/open-webui:v0.13.0-slim` is published for `linux/arm64` (and amd64).

### Checked in the docs, 2026-11-08
For the roadmap's search and documents entries; read through a fetch helper, not yet tried on our version. Sources: https://docs.openwebui.com/features/workspace/models, `/features/workspace/knowledge`, `/features/chat-conversations/web-search` and its `providers/searxng` page, `/features/chat-conversations/rag/` and its `document-extraction` page.
- **Per model** (Workspace → Models, edit a model): capabilities Vision, Web Search, Code Interpreter, Terminal, Image Generation, Usage, Citations, Status Updates, Memory, Builtin Tools, File Upload and Preload files. File Upload off: "an upload in a chat using this model is refused". Web Search: "Enable the configured search provider"; the docs do not say outright that off removes the chat's toggle. Default Features (Web Search, Image Generation, Code Interpreter) start on in every new chat with that model, and users can turn them off per chat. A model's access can be limited to specific users or groups.
- **Web search:** SearXNG is a listed provider, on a page marked as a community contribution "not supported by the Open WebUI team". Its example uses `ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE: "searxng"`, `WEB_SEARCH_RESULT_COUNT`, `WEB_SEARCH_CONCURRENT_REQUESTS` and `SEARXNG_QUERY_URL`; SearXNG must allow JSON output, or answers 403. Search is switched on per chat; `ENABLE_WEB_SEARCH_CONFIRMATION` makes users confirm each search. Search queries are a background task, set under Task Models.
- **Documents:** embedding engines are the built-in SentenceTransformers (skipped by the slim image, 2026-11-06), Ollama, OpenAI and Azure OpenAI. Extraction engines include Tika, Docling, Mistral OCR and External, among others. "Using Entire Document" and "Always Use Full Text" put the whole file into every message, and files below the "Full Text Threshold" go in whole automatically. Changing the embedding model needs a re-index. With native function calling, knowledge is not injected automatically. The RAG page says the token splitter is unavailable on the slim image.
- Not found on the pages read: a global switch that turns file upload off for everyone, the names of the embedding base URL settings, and the default extraction engine.

## OpenRouter catalogue

### Price changes seen, 2026-11-03 and 2026-11-04
- `openai/gpt-oss-120b` at `primeintellect/fp4` had three prices within a day: $0.03 / $0.11, then $0.035 / $0.13, then $0.026 / $0.095 per million tokens. The price check caught the last change, and it moved again within hours ($0.035 / $0.129). The other ten pinned endpoints kept their prices. The entry was replaced by `gpt-oss-120b@coreweave` (`coreweave/fp4`, $0.03 / $0.17) on 2026-11-04.

### From OpenRouter's API, 2026-11-03
Sources: `GET https://openrouter.ai/api/v1/models` (453 models) and `GET https://openrouter.ai/api/v1/endpoints/zdr` (1,090 zero data retention endpoints).
- 141 open-weight models (with a Hugging Face id) have at least one paid zero data retention endpoint.
- 14 models end in `:free`. Only one free text model has a zero data retention endpoint (`xingchen-agi/xing4.0-29b-a4b:free` at Phala).
- `meta-llama/llama-3.2-1b-instruct` has a zero data retention endpoint at Cloudflare ($0.027 / $0.201 per million tokens).
- Endpoints are addressed by slugs that include the variant, e.g. `deepinfra/fp8` or `deepinfra/turbo` (https://openrouter.ai/docs/guides/routing/provider-selection). Routing fields include `order`, `only`, `allow_fallbacks`, `zdr`, `data_collection` and `quantizations`.
- Reasoning defaults: `gpt-oss-120b` and `gpt-oss-20b` reason always (default effort `medium`); `deepseek-v4.1-flash` by default (effort `high`); `qwen3.8-2.4t-a95b` always (default effort `xhigh`); `gemma-4-26b-a4b-it` optionally, off by default.

## Docker on Raspberry Pi OS

### On a Pi 5 with Raspberry Pi OS, 2026-11-04
Pi 5, 8 GB, Docker with cgroup v2.
- The kernel boots with `cgroup_disable=memory`, seen in `/proc/cmdline`, and `docker info` warns `No memory limit support` and `No swap limit support`.
- With that, Docker silently drops `mem_limit`: `docker inspect` shows `HostConfig.Memory` as 0. `tests/chat.bats` also failed on `docker stats`' memory figure, which fits this; the figure itself was not seen.

### Compose, 2026-11-05
- `docker compose up` attaches by default and stops the containers when it exits; `-d`, `--detach` or `--wait` detach it. The environment variables page lists no `COMPOSE_*` variable for it. The service attribute `attach: false` only stops Compose collecting that service's logs. The services page's attributes from `links` onward were read in summary, not verbatim. Sources: https://docs.docker.com/reference/cli/docker/compose/up/, https://docs.docker.com/compose/how-tos/environment-variables/envvars/, https://docs.docker.com/reference/compose-file/services/

### Compose pull and images built on the host, checked 2026-11-06
- `docker compose pull` also tries to pull the image of a service with a `build:` section. When that fails (an image of our own that is in no registry), Compose warns that the image must be built, and still returns the failure as an error unless `--ignore-pull-failures` is given. `--ignore-buildable` skips such services before any pull. A `pull_policy` of `build` or `never` also skips them. Sources: https://docs.docker.com/reference/cli/docker/compose/pull/ and `pkg/compose/pull.go` on Compose's `main` branch (read in summary).
- `docker compose up` builds a service's image only when it is missing, unless `--build` is given: with a fixed `image:` tag, `up` after a `git pull` keeps running the image built before.

## Docker in the cloud sandbox

### 2026-11-03
- Docker 29.9.2 and Compose v5.6.1 are installed. The daemon is not running at session start; started by hand with `dockerd`, it runs containers (`hello-world` confirmed). The cloud sandbox is `x86_64`.

## Model range

### 2026-11-02 (owner)
All sizes are reached through OpenRouter.
- **Smallest:** `llama-3.2-1b-instruct` (1B, served by Cloudflare), then a 1.8B translation model. General-purpose choices stay scarce until 3B.
- **Largest:** `qwen3.8-2.4t-a95b` (2.4T).
- **Same model on several hosts:** `gpt-oss-120b` has over 20, so hosts can be compared directly.
- **Zero data retention:** `lfm-2.5-2.6b` had no zero data retention host listed.
