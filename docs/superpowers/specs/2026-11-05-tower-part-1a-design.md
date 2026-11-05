# Tower, part 1a: see, stop and check

A project: the first part of `tower`, the only interface rapid-selector builds. Status: draft, 2026-11-05, written from a design conversation with the owner; not yet through the builder check or approved.

Part 1b (changing models, roles and budgets from tower) gets its own design afterwards. The arena and benchmarks are phase 2.

## Why

The owner runs everything today from the terminal: scripts to check prices, run the smoke test and register keys, and a dashboard in OpenRouter to see spend. That means remembering what to run and when, and opening three places to see one picture. Tower is the one place to:

- see at a glance what models have cost and how much they are used, today, this week and this month;
- see every setting of the stack, neatly organised;
- stop all spending quickly, which matters more since D1 showed that OpenRouter's key limit stops calls only after their spend is counted (`decisions.md`, step D1);
- have the checks that keep spend honest run by themselves, or with a button.

## Goals, non-goals and anti-goals

**Goals (part 1a):**
1. A first screen with spend today, this week and this month, the balance, the key limit and what is left of it, a forecast for the month, when the limits reset, and the most used roles and models.
2. Reconciliation: the gateway's recorded spend against OpenRouter's, with any gap made obvious.
3. A kill switch at two levels, always visible.
4. The price check on a schedule and on demand, and the smoke test on demand, with results kept and shown.
5. A "Setup" section showing every setting tower can read, read-only.
6. A "Log" section: kill switch changes, check results and balance snapshots.
7. A login, and `/metrics` for Prometheus.

**Non-goals (part 1a):** changing any setting (part 1b); the arena (phase 2); amounts in NOK (USD only, decided 2026-11-05); history beyond the current month (Grafana's job); OpenRouter's account settings (no API for them, left out by the owner); running the level 1 tests or the drain tests (they stay in the terminal).

**Anti-goals:**
- Tower becoming the only way to stop spending. The README's manual ways must keep working without tower.
- A secret value shown anywhere in tower, its logs or its metrics.
- Tower spending money without an explicit action by the owner. The scheduled price check is free; the smoke test runs only when the owner asks, after its cost is shown.
- A kill switch that looks engaged when it is not.

## Constraints

From `CLAUDE.md`, the overall design and the phase 0 build:
- One container, `rapidselector-tower`, image `rapidselector-tower` built from `tower/`, for `linux/arm64`. Port `TOWER_PORT` (4020), bound to `RAPIDSELECTOR_LAN_ADDRESS`. Volume `rapidselector_towerdata` for SQLite. A memory-light service: no memory limit, as for the others.
- Tower reads the gateway through LiteLLM's API, never its database.
- Tower is the only holder of OpenRouter's management key. No other service gets it.
- Secrets are environment variables with fixed names in `.env.example`, from `.env` or secrets-service through `rapidselector.sh`. New: `TOWER_PASSWORD`, `TOWER_SESSION_SECRET`, `OPENROUTER_MANAGEMENT_KEY`, and tower's gateway key (see "Tower's keys").
- Pinned image and library versions, a healthcheck, log rotation, and the `rapidselector` prefix.
- Plain HTTP on the LAN, one password (decided 2026-11-03).
- Development happens without the Pi or real money. What needs them becomes steps in a test procedure for the owner.

## Approaches considered

**Visual level** (owner's choice from three mockups): A, clean and functional (the production stack's Bootstrap look); **B, distinctive (chosen)**: a visual identity of its own, dark, warm and typographic, a nod to Bush's microfilm machine, with custom but simple charts; C, experimental (interactive D3 or canvas maps).

**Stack** (owner's choice): **1, server-rendered Python (chosen)**: FastAPI and Jinja2, an own stylesheet, charts drawn as SVG on the server, `htmx` for parts of a page that update or act, SQLite through Peewee, `pytest`; 2, FastAPI serving data to plain JavaScript with D3 or Observable Plot; 3, Svelte or React in front of FastAPI, with Node tooling and a build step. Reason: the owner's production stack, one language and one test setup, the fewest moving parts, enough for look B. A richer chart in phase 2 can use D3 on its own page.

**Changing settings** (owner's choice, revised the same day): tower first was to show every setting and change none; the owner then chose to let tower change models, roles and budgets with guard rails, and run the checks. Part 1a does the viewing and the checks; part 1b the changing.

## What tower shows

### Header, on every page
`RAPID SELECTOR` and the kill switch state: `● ALL CLEAR` or the active level, with the switch itself. Navigation: **Cost · Usage · Setup · Log**.

### Cost (the first screen)
```
┌ RAPID SELECTOR ─────────────────────────── ● ALL CLEAR · STOP ┐
│ SPENT, NOVEMBER  $7.40          ▓▓▓▓░░░░│░░░  key limit $35   │
│ today $0.31 · this week $2.10 · balance $12.60 · forecast $19  │
│ resets 1 Dec 00:00 UTC (gateway and key: in step)              │
│ ROLES        classify ▓▓▓▓▓▓ 412  summarise ▓▓▓ 238  chat ▓ 131│
│ MODELS       gpt-oss-120b@deepinfra ▓▓▓▓ 380 …                 │
│ RECONCILIATION  gateway $7.40 · OpenRouter $7.42 · Δ $0.02     │
│ CHECKS   price check ok, 06:30 · smoke test ok, 3 Nov  [run]   │
└────────────────────────────────────────────────────────────────┘
```
- **Spend** today, this week (from Monday 00:00 UTC, as OpenRouter counts) and this month, from the OpenRouter key's `usage_daily`, `usage_weekly` and `usage_monthly`, which count what is actually charged.
- **Balance:** `total_credits − total_usage` from `GET /api/v1/credits`.
- **Key limit** and what is left, with the gateway's global budget marked on the same bar.
- **Forecast** for the month: spend so far divided by the days passed, times the days in the month. Shown as an estimate. (Claude's call.)
- **Resets:** the key limit's `limit_reset` and the gateway's budget windows. A mismatch is shown, not hidden.
- **Top roles and models:** calls and spend for the chosen period, today, week or month, from the gateway. ROLES counts the four roles; MODELS counts each model at its host (`model@host`) across every name that uses it, roles and experiment names together, so `chat` and `gpt-oss-120b@deepinfra` both count towards `gpt-oss-120b` at DeepInfra. The two rows are two views of the same calls, not parts of one total. (Claude's call, from the owner's "which models are most used, which roles are most used".)
- **Reconciliation:** see below.
- **Checks:** the latest price check and smoke test, with their time and result.

### Usage
Calls, tokens and spend per role, per experiment name and per key, for today, this week and this month. Roles and experiment names are listed apart, so permanent use and experiments can be told apart.

### Setup (read-only in part 1a)
Every setting tower can read, grouped:
- **Models:** each role and experiment name with its model, pinned host and quantisation, fallbacks off or on, zero data retention, price per million tokens in and out, default `max_tokens`, and the price check's latest result for it. From the gateway's `/model/info`.
- **Teams and keys:** budgets, spend, reset, allowed names, rate limits. From `/team/info` and `/key/info`.
- **OpenRouter key:** limit, reset, usage, whether disabled, its masked label. From the management API.
- **Management key:** days until it expires (decided: one year).
- **Gateway settings:** global budget and window, spend log retention. From the gateway's API where it shows them; otherwise from `gateway/config.yaml`, mounted read-only into tower and labelled as the file. (Claude's call.)
- **Open WebUI:** its non-secret settings, read from `docker-compose.yml`, mounted read-only into tower. (Claude's proposal; the owner has not yet confirmed it.)
- **Secrets:** tower's own secrets by name, shown only as set or not set. Tower is not given the others; the page says that Compose refuses to start the stack unless every secret in `.env.example` is set. (Claude's call: passing other services' secrets, or even a list of them, into tower would widen what it holds for little gain.)

### Log
Kill switch changes (who, when, which level, result), each price check and smoke test run, and balance snapshots. Newest first.

## Reconciliation

- **This month:** the gateway's recorded spend for the calendar month (UTC), summed from its spend logs and including calls made with the master key, since every call uses the same OpenRouter key, against that key's `usage_monthly`. The difference in dollars and percent. Flagged when it is more than $0.05 or 5% of the month's spend, whichever is larger. (Claude's call; to revisit after real use.)
- **Per completed day:** OpenRouter's `GET /api/v1/activity` for the gateway's key (`api_key_hash`) gives each day's usage per model and host, for the last 30 completed days; the gateway's spend per day and model is set beside it. Today is not in OpenRouter's activity, so today's line uses the key's `usage_daily`.
- **Known causes of small gaps:** OpenRouter counts spend a little late (D1), and costs below a millionth of a dollar are rounded in some of its views (D4). A gap that persists past a day is the one that matters.

## Kill switch

**Level 1, block every virtual key in the gateway.** LiteLLM has no call to block all keys or a team at once (`provider-facts.md`), so tower lists the virtual keys and blocks each with `POST /key/block`, except its own gateway key. It records which keys it blocked, so releasing unblocks exactly those, and never a key that was blocked for another reason. A key added while level 1 is engaged is blocked too, on tower's next check (every minute). Quick to reverse; stops clients, but not a call already running.

**Level 2, disable the OpenRouter inference key** with `PATCH /api/v1/keys/{hash}` and `{"disabled": true}`. This stops everything, including the gateway itself. Engaging level 2 also engages level 1. The key's `hash` is found by listing the keys with the management key and matching the name set in `.env` (`OPENROUTER_INFERENCE_KEY_NAME`, default `rapidselector-gateway`); the inference key itself is not given to tower.

**State shown** is read back from the source after every change: the keys' `blocked` flags in the gateway and the key's `disabled` flag at OpenRouter. If reading back fails, tower shows the state as unknown, in warning colours, not as engaged.

**Engaging** is one click and a confirmation in the page (no browser pop-ups). **Releasing** is a deliberate action: a separate button and the word `release` typed. Every change is written to the Log with the time and result.

**Whether OpenRouter's disable takes effect at once is not documented.** It is tested at level 3.

## Checks

### Price check
The logic of `tests/check-prices.sh`, in Python in tower: for each name in the gateway's `/model/info`, its pinned endpoint must be in OpenRouter's public `/api/v1/endpoints/zdr` list, at the price configured, not in the flex tier, and without Safety Retention. It checks what the gateway actually runs, not the file. Runs daily at 06:30 UTC and from a button; free. A failure shows on the Cost screen, in the Log, and as a metric. `tests/check-prices.sh` stays for the terminal until part 1b. (Claude's calls: the time, and keeping both.)

### Smoke test
The logic of `scripts/smoke-test.sh`: one small call per role, or per name, with `KEY_SMOKE_TEST`, which tower is given; each must answer with a recorded cost above zero, and a model outside the allowlist and the `/openrouter` pass-through must be refused. Before it runs, tower shows the worst case (each name's price for its input and 256 output tokens) and asks for confirmation. Results go to the Log and the Cost screen. `scripts/smoke-test.sh` stays for the terminal.

## Tower's keys

- **Gateway:** tower needs to read spend and block keys. Preferred: a key owned by a gateway user with role `proxy_admin`, narrowed with `allowed_routes` to the routes tower uses (question 17). If that does not work in v1.106.6 at level 1, tower uses `LITELLM_MASTER_KEY`, and this is recorded.
- **Smoke test:** the existing `KEY_SMOKE_TEST` ($1 a month).
- **OpenRouter:** `OPENROUTER_MANAGEMENT_KEY`, created with a one-year expiry. Its expiry date is read from the key list and shown, and exported as a metric for a Grafana alert 30 days before.

## Metrics

`/metrics`, no login, values and aliases only, prefixed `rapidselector_`, for example: `rapidselector_openrouter_balance_usd`, `rapidselector_key_limit_usd`, `rapidselector_key_limit_remaining_usd`, `rapidselector_key_usage_usd{period="day|week|month"}`, `rapidselector_reconciliation_diff_usd`, `rapidselector_kill_switch_level` (0, 1 or 2), `rapidselector_price_check_ok`, `rapidselector_price_check_last_run_timestamp_seconds`, `rapidselector_smoke_test_ok`, `rapidselector_management_key_expires_timestamp_seconds`, `rapidselector_upstream_ok{source="gateway|openrouter"}`.

## Data and refreshing

- Tower reads the gateway and OpenRouter when a page is opened, with a short cache (about 30 seconds) so a page with several panels does not call the same thing several times. A background loop every minute updates the metrics, keeps level 1's keys blocked, and takes a balance snapshot every hour. (Claude's calls.)
- SQLite in `rapidselector_towerdata`: the Log, check results, balance snapshots, and which keys level 1 blocked. Backed up by a new backup-orchestrator job in `production`, or the README's fallback.
- If the gateway or OpenRouter cannot be reached, tower still loads, shows what is missing in warning colours, and keeps the kill switch reachable.

## Look

Look B, from the mockup: a dark, warm background, a serif for headings and large numbers, a monospace for labels and small figures, an amber accent, bars and progress lines as plain shapes. Danger states (kill switch engaged, failed check, gap in reconciliation) use a colour that stands apart from the amber. Readable on a phone as well as a desktop. Its own stylesheet; no Bootstrap. The details are the builder's, checked with the owner on screen.

## Testing

- **Level 1 (no Pi, no money):** `pytest` for tower's own logic; and tower against the real LiteLLM image and the fake upstream, extended with OpenRouter's management routes (`/keys`, `/keys/{hash}`, `/credits`, `/activity`, `/endpoints/zdr`). Covers: the kill switch's both levels, including releasing only what it blocked, a key added while engaged, and a failed read-back; the price check against a saved endpoint list; reconciliation's flag; that no secret value appears in any page, log or metric; login.
- **To try first at level 1:** usage per role and model from `/user/daily/activity` or `/spend/logs` in v1.106.6 (if neither gives it per name, Usage falls back to OpenRouter's per model and host figures for completed days, without the split by role, and the owner is told); the `proxy_admin` key with `allowed_routes`; whether the management key appears in `GET /api/v1/keys` with its expiry (if not, an owner-set `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT`).
- **Level 2 and 3 (owner, on the Pi):** a test procedure, written with the plan, covering: real balance and key figures against OpenRouter's dashboard; level 1 stopping Node-RED's and chat's calls; level 2 disabling the real key, how fast a call is then refused, and re-enabling it; the smoke test's cost against its estimate.

## Changes in the `production` repository

A Prometheus target for tower, a backup job for tower's SQLite, the Grafana dashboard, and alerts: kill switch engaged, price check failed or stale, reconciliation gap, balance low, management key expiring within 30 days.

## Left to the builder

The page layout within each section, chart details, the exact metric names beyond those above, how the short cache works, the SQLite schema, and how the fakes are extended.
