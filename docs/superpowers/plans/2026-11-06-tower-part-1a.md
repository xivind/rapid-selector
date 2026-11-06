# Tower, part 1a: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `tower`, a FastAPI service in its own container, that shows spend, usage and every setting, runs the price check and the smoke test, has a two-level kill switch, keeps a Log in SQLite, and exports `/metrics`, with the matching changes in the `production` repository and a level 2 and 3 test procedure.

**Architecture:** One Python package, `tower/tower/`, served by uvicorn. Pure logic (kill switch state, checks, cost summary, reconciliation) lives in modules with no I/O and is unit-tested with `pytest`. Two thin clients (`GatewayClient`, `OpenRouterClient`) wrap `httpx` with a 30-second cache; pages are Jinja2 templates with server-drawn SVG and `htmx`; a background loop updates metrics, keeps level 1 enforced, snapshots the balance and runs the daily price check. Level 1 integration tests are bats files against the real LiteLLM image and the fake upstream, extended with OpenRouter's management routes.

**Tech Stack:** Python (pinned `python:*-alpine` base, see Task 1), FastAPI, uvicorn, Jinja2, Peewee (SQLite), `httpx`, `prometheus_client`, PyYAML, `python-multipart` (forms), `itsdangerous` (Starlette's signed session cookie), `htmx` 2.x vendored as a static file, `pytest`; `uv` for the lock file. Level 1: Docker Compose, bats 1.11.0, the existing fakes.

**Spec:** `docs/superpowers/specs/2026-11-05-tower-part-1a-design.md`. Read it, `CLAUDE.md`, and the 2026-11-05 tower entries in `docs/decisions.md`. Facts the code relies on are in `docs/provider-facts.md` (OpenRouter's management API, LiteLLM's spend reports and blocking, both 2026-11-05).

## Global Constraints

- Branch `tower-part-1a`, from `phase-0-walkthrough` (or from `main` once that is merged). Commit after each task; messages end with the attribution lines from the session's system reminder.
- Container `rapidselector-tower`, image `rapidselector-tower:<version in tower/pyproject.toml>` built from `tower/`, buildable for `linux/arm64`. Container port 8000, published as `"${RAPIDSELECTOR_LAN_ADDRESS:?…}:${TOWER_PORT:-4020}:8000"`. Volume `towerdata` (so `rapidselector_towerdata`) at `/data`; SQLite file `/data/tower.db`. `./gateway/config.yaml` and `./docker-compose.yml` mounted read-only under `/config/`. Healthcheck on `/health`, the `*logging` anchor, `restart: unless-stopped`, no memory limit, no Docker socket.
- `depends_on: gateway: condition: service_started`, not `service_healthy`: tower must start and keep the kill switch reachable when the gateway is down.
- New secrets, added to `RAPIDSELECTOR_SECRETS` in `scripts/lib.sh`, `.env.example` and Compose with `${NAME:?…}`: `TOWER_PASSWORD`, `TOWER_SESSION_SECRET`, `OPENROUTER_MANAGEMENT_KEY`, `TOWER_GATEWAY_KEY`. Tower also gets `KEY_SMOKE_TEST`. It gets no other secret, never `LITELLM_MASTER_KEY` unless Task 2 records that the `proxy_admin` key does not work, and never `RAPIDSELECTOR_OPENROUTER_KEY`.
- New settings (not secret) in `.env.example`: `TOWER_PORT=4020`, `OPENROUTER_INFERENCE_KEY_NAME=rapidselector-gateway`, `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT=` (optional, ISO date). Tower-internal overrides for tests only: `TOWER_GATEWAY_URL` (default `http://gateway:4000`), `OPENROUTER_API_BASE_URL` (default `https://openrouter.ai/api/v1`), `TOWER_DATA_DIR` (`/data`), `TOWER_CONFIG_DIR` (`/config`).
- **No secret value anywhere** in a page, a log line, `/metrics`, SQLite, an exception message or a test's saved output. Errors name the source and the HTTP status, never a header or a URL with a key.
- All times UTC. Week from Monday 00:00 UTC. Month from the 1st 00:00 UTC.
- Cache 30 seconds per client call. Background loop every 60 seconds; balance snapshot every hour; price check daily at 06:30 UTC and on demand.
- HTTP timeouts: 5 s for reads, 15 s for writes (block, unblock, disable), 120 s for a smoke test call.
- Reconciliation flagged when `|gateway − OpenRouter| > max($0.05, 5% of OpenRouter's month)`.
- Smoke test: `max_tokens` 256, `reasoning_effort: "low"` for entries with `model_info.reasoning == true`, prompt "Reply with the word ok."; worst case shown first = Σ over names of (50 × input price + 256 × output price); runs only after the owner confirms.
- Kill switch: engaging is one click plus a confirmation inside the page (no `alert`/`confirm` pop-ups); releasing is one level at a time, with the word `release` typed. Tower releases only what it engaged.
- No external assets at runtime: `htmx` vendored under `static/`, fonts from the system stack (a serif for headings and figures, `ui-monospace` for labels), no CDN.
- Pin every dependency in `tower/uv.lock`, each at the newest release at least two weeks old when Task 1 runs; record the versions in `docs/provider-facts.md` with the date. Raising a dependency with a real effect on the stack goes to the owner first (`CLAUDE.md`).
- Tests: `cd tower && uv run pytest` for unit tests (no network, `httpx.MockTransport`); `tests/run.sh tests/tower*.bats tests/fakes.bats tests/stack.bats` for level 1 (needs Docker; not beside the real stack). On a machine without Docker, run the bats files in the cloud sandbox, or follow "For developers on this machine" in `docs/test-procedures/phase-0-status.md`.
- Nothing in this plan spends real money. What needs the Pi or OpenRouter goes into `docs/test-procedures/tower-1a.md` (Task 13).
- If a level 1 finding breaks an assumption in the spec, stop and report to the owner before continuing. Observations go to `docs/provider-facts.md` with the version and date.

## Review Focus

1. **The gateway or OpenRouter is down or slow:** every page still renders within about 6 seconds, the missing panels say what is missing in warning colours, and the kill switch stays usable for the level whose source is up. Test in Task 9 (`test_cost_page_renders_with_gateway_down`) and Task 12.
2. **A block call fails halfway through engaging level 1:** the keys blocked so far are recorded, the state reads back as partly engaged (not "ALL CLEAR", not fully engaged), and engaging again blocks the rest. Test in Task 6 (`test_engage_level1_partial_failure`).
3. **Engaging twice, or the loop and a click at once:** no key is recorded twice, and a key that was already blocked before tower engaged is never recorded as tower's, so it is never released by tower. Test in Task 6 (`test_engage_is_idempotent`, `test_key_blocked_before_engage_is_not_released`).
4. **The smoke test while level 1 is engaged, or the smoke-test key's budget is spent:** refused before any call, with the reason shown, and nothing spent. Test in Task 7 (`test_smoke_refused_while_level1_engaged`).
5. **Dates at the edges:** on the 1st at 00:10 UTC the forecast is not absurd, a Sunday 23:59 UTC call belongs to that week, and a container clock in another time zone changes nothing. Test in Task 8 (`test_period_bounds_*`, `test_forecast_on_the_first`).

---

## File structure

```
tower/Dockerfile                     uv from a pinned image, python alpine, non-root user
tower/pyproject.toml, tower/uv.lock  dependencies, pytest settings, version
tower/tower/settings.py              Settings and load_settings(env)
tower/tower/clients.py               Unavailable, TTL cache, GatewayClient, OpenRouterClient
tower/tower/store.py                 Peewee models, init_db, log helpers
tower/tower/backup.py                python -m tower.backup: consistent SQLite copy to stdout
tower/tower/killswitch.py            SwitchState, read_state, engage, release, enforce
tower/tower/checks.py                price check, smoke plan and run
tower/tower/summary.py               periods, forecast, reconciliation, top roles and models, usage tables
tower/tower/setup_view.py            Setup page data from the APIs and the mounted files
tower/tower/metrics.py               registry and update from a snapshot
tower/tower/loop.py                  background loop
tower/tower/app.py                   create_app(), auth, routes
tower/tower/templates/               base, login, cost, usage, setup, log, partials/
tower/tower/static/                  tower.css, htmx.min.js
tower/tests/test_*.py                unit tests
tests/fakes/upstream.py              + OpenRouter management routes
tests/gateway-api.bats               the LiteLLM API shapes tower relies on (Task 2)
tests/tower.bats                     tower against the test stack (Task 12)
scripts/setup-keys.sh                + tower's gateway user and key
docker-compose.yml, .env.example, scripts/lib.sh, README.md
docs/test-procedures/tower-1a.md     levels 2 and 3
```

---

### Task 1: Skeleton, container and settings

**Files:**
- Create: `tower/Dockerfile`, `tower/pyproject.toml`, `tower/uv.lock`, `tower/tower/__init__.py`, `tower/tower/settings.py`, `tower/tower/app.py`, `tower/tests/test_settings.py`, `tower/tests/test_app.py`, `tower/.dockerignore`
- Modify: `docker-compose.yml`, `.env.example`, `scripts/lib.sh`, `tests/helpers.bash` (`ensure_test_env`: `TOWER_GATEWAY_KEY` gets an `sk-test-` value like the `KEY_*` names, since LiteLLM key values must start with `sk-`), `tests/rapidselector.bats` (its stub lists the secret names), `tests/stack.bats`, `tests/checks.bats` (image list), `.gitignore` (`tower/.venv/`)

**Interfaces:**
- Produces: `Settings` (frozen dataclass): `password, session_secret, management_key, gateway_key, smoke_key: str`; `gateway_url, openrouter_url, inference_key_name: str`; `management_key_expires_at: datetime | None`; `data_dir, config_dir: Path`. `load_settings(env: Mapping[str, str]) -> Settings` raises `SettingsError(name)` naming the first missing secret, in the order of the constraint list. `Settings.secret_values() -> list[str]` (for redaction and tests). `create_app(settings, *, gateway=None, openrouter=None, start_loop=True) -> FastAPI`.

- [ ] **Step 1: Write tests.** `test_settings.py`: `test_missing_secret_names_it` (env without `OPENROUTER_MANAGEMENT_KEY` → `SettingsError` whose `str()` contains the name and none of the other values); `test_defaults` (`gateway_url == "http://gateway:4000"`, `openrouter_url == "https://openrouter.ai/api/v1"`, `inference_key_name == "rapidselector-gateway"`, `management_key_expires_at is None`); `test_expiry_parsed` (`"2027-11-06"` → `datetime(2027, 11, 6, tzinfo=UTC)`). `test_app.py`: `test_health` (`GET /health` → 200 `{"status": "ok"}` with `start_loop=False`). In `tests/stack.bats`, add `tower is published on the LAN address only` and `tower mounts config read-only and has no docker socket`, reading `docker compose config` as the existing tests do.
- [ ] **Step 2: Run** `cd tower && uv run pytest` and the two bats tests — expected FAIL.
- [ ] **Step 3: Implement.** `pyproject.toml` with the dependencies from the Tech Stack, `[tool.pytest.ini_options] testpaths = ["tests"]`, version `0.1.0`; `uv lock`. Dockerfile: base `python:<3.x.y>-alpine<3.z>` (prefer `3.15.2-alpine3.24`, already used by the fakes and checked for arm64; if a dependency has no musl wheel for it, use the newest 3.14 alpine and say so in the commit), uv copied from a pinned `ghcr.io/astral-sh/uv:<version>`, `uv sync --frozen --no-dev`, a non-root user owning `/data`, `CMD ["uvicorn", "--factory", "tower.app:main", "--host", "0.0.0.0", "--port", "8000"]`, where `main()` returns `create_app(load_settings(os.environ))`, so importing `tower.app` in tests needs no environment. Compose service as in Global Constraints; volume `towerdata`. Add the four secrets to `RAPIDSELECTOR_SECRETS` and `.env.example` (with how to generate each; the management key with a one-year expiry), and the settings.
- [ ] **Step 4: Run** pytest and `tests/run.sh tests/stack.bats tests/checks.bats tests/rapidselector.bats` — expected PASS; `tests/check-arm64.sh` lists both new images (tower's base and uv) with `ok`.
- [ ] **Step 5: Commit** `tower: skeleton, container and settings`.

### Task 2: The LiteLLM API tower relies on, tried at level 1

This is the spec's "to try first". The bats file is the probe, and stays as a guard against LiteLLM upgrades.

**Files:**
- Create: `tests/gateway-api.bats`
- Modify: `scripts/setup-keys.sh` (tower's user and key), `tests/keys.bats`, `docs/provider-facts.md`, `docs/decisions.md` (question 17)

**Interfaces:**
- Produces, `setup-keys.sh`: a gateway user `tower` with `user_role: proxy_admin`, and a key with value `$TOWER_GATEWAY_KEY`, alias `tower`, no team, no budget, `allowed_routes` = `TOWER_ROUTES` (the exact list this task finds necessary). `require_env` gains `TOWER_GATEWAY_KEY`.
- Produces, for Task 3: the request and response shapes below, recorded in `provider-facts.md` under "Tower's routes, v1.106.6, <date>".

- [ ] **Step 1: Write `tests/gateway-api.bats`** against the full test stack (`stack_up`, then `run_setup_keys`), with tower's key unless noted:
  - `model info shows pin, prices, max_tokens and kind`: `GET /model/info` has, for `classify`, `.litellm_params.extra_body.provider.order == ["deepinfra/fp8"]`, a positive `.model_info.input_cost_per_token`, `.litellm_params.max_tokens == 1024`, `.model_info.rapidselector_kind == "role"`, and no `api_key` value.
  - `keys can be listed with their blocked flag`: `GET /key/list?return_full_object=true` includes aliases `node-red`, `chat`, `smoke-test`, `tower`, each with a token hash and `blocked`.
  - `a key can be blocked by hash and unblocked`: `POST /key/block {"key": <hash of node-red>}`, then `gw_call $KEY_NODE_RED classify` is refused (record the status); `POST /key/unblock` and the call answers 200.
  - `spend per name, key and day is readable`: after one `gw_call` each to `classify` (node-red) and `gpt-oss-120b@deepinfra` (smoke-test) and the batch write, at least one of `GET /user/daily/activity?start_date=…&end_date=…` and `GET /spend/logs?start_date=…&end_date=…` gives, per day, the model name as the client called it, the key alias or hash, requests, tokens and spend matching the two calls.
  - `team and key info show budgets and reset times`: `/team/info?team_id=experiments` has `max_budget`, `budget_duration`, `budget_reset_at`; `/key/info?key=…` the same for `smoke-test`.
  - `global budget readable or not`: whether any route tower's key may call returns `max_budget` 32 and `budget_duration` `30d`, and the spend log retention (`90d`). If none does, assert nothing and record that Setup reads `gateway/config.yaml` for them.
  - `tower's key cannot reach the pass-through or change models`: `/openrouter/v1/chat/completions`, `POST /model/new`, `POST /key/delete` → refused.
- [ ] **Step 2: Run** `tests/run.sh tests/gateway-api.bats` — expected FAIL (no tower key yet).
- [ ] **Step 3: Add tower's user and key to `setup-keys.sh`**, with `TOWER_ROUTES` narrowed to the routes the tests above need, and a `tests/keys.bats` case `tower's key exists with only its routes`. If a `proxy_admin` key with `allowed_routes` cannot block or list keys in v1.106.6, stop: record it, tell the owner, and with their agreement give tower `LITELLM_MASTER_KEY` instead of `TOWER_GATEWAY_KEY` (question 17).
- [ ] **Step 4: Run** the file until it passes, adjusting only the probes' expectations to what v1.106.6 really does. **If neither spend route gives spend per name, stop and tell the owner** (the spec's fallback: Usage from OpenRouter's per model and host figures for completed days, without the split by role). Write the shapes to `provider-facts.md` and the answer to question 17 to `decisions.md`.
- [ ] **Step 5: Commit** `tower: probe LiteLLM's API and add tower's gateway key`.

### Task 3: Clients for the gateway and OpenRouter

**Files:**
- Create: `tower/tower/clients.py`, `tower/tests/test_clients.py`

**Interfaces:**
- Consumes: Task 2's shapes; `Settings`.
- Produces:
  - `class Unavailable(Exception)` with `source: str` (`"gateway"` or `"openrouter"`) and `reason: str` (status or error class; never a header, key or full URL).
  - `@dataclass GatewayKey(token_hash: str, alias: str | None, team_id: str | None, blocked: bool)`.
  - `@dataclass UsageRow(day: date, name: str, key_alias: str | None, calls: int, tokens_in: int, tokens_out: int, spend_usd: float)`.
  - `GatewayClient(base_url, key, http: httpx.Client, ttl=30, clock=time.monotonic)`: `model_info() -> list[dict]`, `keys() -> list[GatewayKey]`, `block(token_hash) -> None`, `unblock(token_hash) -> None`, `team(team_id) -> dict`, `key(alias_or_hash) -> dict`, `usage(start: date, end: date) -> list[UsageRow]`, `own_hash() -> str` (hash of tower's key, computed as LiteLLM does, per Task 2).
  - `OpenRouterClient(base_url, management_key, inference_key_name, http, ttl=30, clock=…)`: `inference_key() -> dict` (lists `/keys`, matches `name == inference_key_name`, then `GET /keys/{hash}`; result includes `hash`), `management_key_expiry() -> datetime | None` (from the key list if the management key appears there), `credits() -> dict`, `activity(key_hash) -> list[dict]`, `zdr_endpoints() -> list[dict]` (public, sent without the management key), `set_disabled(key_hash, disabled: bool) -> None`.
  - Writes (`block`, `unblock`, `set_disabled`) bypass the cache and clear it.

- [ ] **Step 1: Write tests** with `httpx.MockTransport`: `test_cache_reuses_within_ttl` (two `model_info()` calls within 30 s → one request; after 31 s on a fake clock → two); `test_write_clears_cache`; `test_unavailable_on_timeout_and_5xx` (`source == "gateway"`, `reason` like `"HTTP 503"`); `test_no_secret_in_errors` (with key `sk-secret-123`, every `Unavailable` text and every log record captured by `caplog` lacks it); `test_zdr_sent_without_auth`; `test_inference_key_found_by_name` and `test_inference_key_missing` (`Unavailable` with reason `"no key named rapidselector-gateway"`); `test_usage_rows` (from a Task 2 response sample saved in `tower/tests/samples/`).
- [ ] **Step 2: Run** `uv run pytest tests/test_clients.py` — expected FAIL.
- [ ] **Step 3: Implement** with one `httpx.Client` per client, the timeouts from Global Constraints, and a small dict-based TTL cache keyed by method and path.
- [ ] **Step 4: Run** — expected PASS.
- [ ] **Step 5: Commit** `tower: gateway and OpenRouter clients`.

### Task 4: Store and backup

**Files:**
- Create: `tower/tower/store.py`, `tower/tower/backup.py`, `tower/tests/test_store.py`

**Interfaces:**
- Produces: Peewee models `LogEntry(at: datetime UTC, kind: str, actor: str, ok: bool | None, summary: str, detail: str (JSON))` with `kind` in `kill_switch`, `price_check`, `smoke_test`, `balance`; `BlockedKey(token_hash: str primary key, alias: str | None, blocked_at)`; `Flag(name: str primary key, value: str)` (holds `level2_by_tower`). `init_db(path: Path) -> None` (WAL mode, creates tables). `log(kind, actor, ok, summary, detail: dict) -> LogEntry`. `latest(kind) -> LogEntry | None`. `entries(limit=200) -> list[LogEntry]`, newest first. `python -m tower.backup` writes a consistent copy of `$TOWER_DATA_DIR/tower.db` to stdout (SQLite backup API into a temp file, then streamed).

- [ ] **Step 1: Write tests:** `test_log_and_latest`; `test_entries_newest_first`; `test_blocked_key_unique` (inserting a hash twice keeps one row); `test_backup_is_a_valid_database` (run `backup.main()` into a buffer, open the bytes as SQLite, `PRAGMA integrity_check` → `ok`, the log row present); `test_detail_never_holds_secrets` is covered where details are written (Tasks 6 and 7).
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — expected PASS.
- [ ] **Step 5: Commit** `tower: SQLite store and backup command`.

### Task 5: Login

**Files:**
- Modify: `tower/tower/app.py`
- Create: `tower/tower/templates/base.html`, `tower/tower/templates/login.html`, `tower/tests/test_auth.py`

**Interfaces:**
- Produces: Starlette `SessionMiddleware` with `settings.session_secret`, cookie `tower_session`, `same_site="strict"`, `https_only=False` (plain HTTP on the LAN), 30-day max age. Dependency `require_login(request)` that redirects `GET`s to `/login` and answers `401` to other methods. Open without login: `/health`, `/metrics`, `/login`, `/static/*`. `POST /login` (form `password`), `POST /logout`.

- [ ] **Step 1: Write tests:** `test_pages_redirect_to_login`; `test_wrong_password_refused` (200 page with a message, no session); `test_right_password_logs_in` (then `GET /` → 200); `test_password_compared_in_constant_time` (implementation uses `hmac.compare_digest`; assert by patching it and checking it was called); `test_login_throttled` (after 5 wrong tries within a minute from one client, the 6th is refused with 429 even with the right password, and works again after 60 s on a fake clock); `test_post_without_session_is_401`.
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement.** `base.html` holds the header (`RAPID SELECTOR`, the kill switch partial slot, navigation **Cost · Usage · Setup · Log**) and loads `/static/tower.css` and `/static/htmx.min.js`.
- [ ] **Step 4: Run** — expected PASS.
- [ ] **Step 5: Commit** `tower: login`.

### Task 6: Kill switch

**Files:**
- Create: `tower/tower/killswitch.py`, `tower/tower/templates/partials/killswitch.html`, `tower/tests/test_killswitch.py`
- Modify: `tower/tower/app.py`

**Interfaces:**
- Consumes: `GatewayClient.keys/block/unblock/own_hash`, `OpenRouterClient.inference_key/set_disabled`, store.
- Produces:
  - `@dataclass SwitchState(level: int | None, outside_tower: bool, level1_complete: bool, blocked_by_tower: list[str], blocked_outside: list[str], openrouter_disabled: bool | None, problems: list[str])`. `level` is 2 when the OpenRouter key reads back disabled, else 1 when any key other than tower's reads back blocked, else 0; `None` when a source needed to decide cannot be read. `outside_tower` is true when the key is disabled without `level2_by_tower`, or a key is blocked that is not in `BlockedKey`.
  - `read_state(keys: list[GatewayKey] | Unavailable, or_key: dict | Unavailable, tower_blocked: set[str], level2_by_tower: bool, own_hash: str) -> SwitchState` (pure).
  - `engage(level: int, gw, orc, actor: str) -> SwitchState`: level 1 blocks every key that is not tower's and not already blocked, recording each one only after its block call succeeds; level 2 does level 1, then disables the OpenRouter key and sets `level2_by_tower`. Logs one `kill_switch` entry with the result, then reads back.
  - `release(level: int, gw, orc, actor: str) -> SwitchState`: level 2 re-enables the key only if `level2_by_tower`; level 1 is refused while the key is disabled, and unblocks only `BlockedKey` rows, deleting each after its unblock succeeds. Logs, then reads back.
  - `enforce(gw) -> list[str]`: when `BlockedKey` is non-empty (level 1 engaged by tower), blocks keys added since and records them; returns their aliases.
  - Routes: `GET /partials/killswitch`; `POST /kill/engage/{level}` (form `confirm=yes`, set by the in-page confirmation step); `POST /kill/release/{level}` (form `word` must equal `release`). All need login and answer with the partial.

- [ ] **Step 1: Write tests** (fake clients in memory): `test_read_state_all_clear`; `test_read_state_unknown_when_gateway_down` (`level is None`, a problem naming the gateway); `test_level2_outside_tower`; `test_key_blocked_outside_tower`; `test_engage_level1_blocks_all_but_tower`; `test_engage_level1_partial_failure` (third block raises → two recorded, `level1_complete` false, state level 1, problem listed; engaging again blocks the rest); `test_engage_is_idempotent`; `test_key_blocked_before_engage_is_not_released`; `test_engage_level2_also_engages_level1`; `test_release_level1_refused_while_level2`; `test_release_level2_leaves_level1`; `test_release_level2_never_enables_a_key_disabled_outside`; `test_enforce_blocks_new_key`; `test_release_requires_typed_word` (route, `word=Release` → 400, nothing changed); `test_failed_readback_shows_unknown_not_engaged` (block succeeds, read-back raises → partial shows "unknown" and the warning class, not "engaged"); `test_log_detail_has_no_secrets`.
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement.** The partial shows `● ALL CLEAR`, `LEVEL 1`, `LEVEL 2`, or `STATE UNKNOWN`, the outside-tower note with where to release it ("OpenRouter's dashboard" or "the gateway's admin UI, /ui"), the engage button with its two-step confirmation, and one release form per engaged level.
- [ ] **Step 4: Run** — expected PASS.
- [ ] **Step 5: Commit** `tower: two-level kill switch`.

### Task 7: Price check and smoke test

**Files:**
- Create: `tower/tower/checks.py`, `tower/tower/templates/partials/checks.html`, `tower/tests/test_checks.py`, `tower/tests/samples/zdr.json` (built from `gateway/config.yaml` as `tests/checks.bats` does)
- Modify: `tower/tower/app.py`

**Interfaces:**
- Produces:
  - `@dataclass PriceResult(name: str, slug: str, ok: bool, reason: str)`; `check_prices(models: list[dict], endpoints: list[dict]) -> list[PriceResult]`: the logic and failure reasons of `tests/check-prices.sh` (no endpoint for the slug; `service_tier == "flex"`; `safety_retention == true`; input or output price differs by ≥ 1e-15), reading each entry's model id from `litellm_params.model` without `openrouter/`, its slug from `extra_body.provider.order[0]` and its prices from `model_info`.
  - `run_price_check(gw, orc, actor) -> list[PriceResult]`: logs a `price_check` entry with `ok` = all ok.
  - `@dataclass SmokePlan(names: list[tuple[str, bool]], worst_case_usd: float)` (name, reasoning); `plan_smoke(models, scope: Literal["roles", "all"]) -> SmokePlan`.
  - `@dataclass SmokeResult(rows: list[tuple[str, int, float]], refusals: list[tuple[str, int]], total_usd: float, ok: bool, refused_reason: str | None)`; `run_smoke(plan, switch: SwitchState, budget_left_usd: float | None, gateway_url, smoke_key, http) -> SmokeResult`, where the route reads `budget_left_usd` from `GatewayClient.key("smoke-test")` (`max_budget − spend`, `None` when it has no budget): refuses before any call when `switch.level` is not 0 or `budget_left_usd` is below the worst case; otherwise the calls and the two probes of `scripts/smoke-test.sh` (`openai/gpt-4o` must get 4xx; `/openrouter/v1/chat/completions` must get 401 or 403). Logs a `smoke_test` entry.
  - Routes: `POST /checks/price`; `GET /checks/smoke?scope=roles|all` (shows the names and worst case with a confirm button); `POST /checks/smoke` (form `scope`, `confirm=yes`).

- [ ] **Step 1: Write tests:** `test_price_all_ok`; one test per failure reason, with the reason text; `test_price_reads_what_the_gateway_runs` (a `model_info` entry whose price differs from the file fails, though the file is untouched); `test_worst_case` (two names with prices 1e-7/2e-7 and 3e-7/4e-7 → `50*1e-7 + 256*2e-7 + 50*3e-7 + 256*4e-7`); `test_smoke_refused_while_level1_engaged` (no request made); `test_smoke_refused_when_budget_too_low`; `test_smoke_zero_cost_fails`; `test_smoke_probe_not_refused_fails`; `test_reasoning_gets_low_effort`.
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — expected PASS.
- [ ] **Step 5: Commit** `tower: price check and smoke test`.

### Task 8: Cost summary, usage and reconciliation

**Files:**
- Create: `tower/tower/summary.py`, `tower/tests/test_summary.py`

**Interfaces:**
- Consumes: `UsageRow`, `OpenRouterClient` result dicts, `model_info`.
- Produces (all pure, `now` passed in, UTC):
  - `period_bounds(now: datetime) -> dict[str, tuple[datetime, datetime]]` for `"day"`, `"week"`, `"month"`.
  - `forecast(spent_month: float, now: datetime) -> float` = `spent_month / max(elapsed_days, 1.0) * days_in_month`, where `elapsed_days` is fractional days since the month began.
  - `@dataclass Reconciliation(gateway_usd, openrouter_usd, diff_usd, diff_pct: float | None, flagged: bool)`; `reconcile(gateway_usd, openrouter_usd) -> Reconciliation`.
  - `@dataclass DayLine(day: date, model: str, host: str, gateway_usd: float, openrouter_usd: float, flagged: bool)`; `reconcile_days(rows: list[UsageRow], activity: list[dict], models: list[dict], today_openrouter_usd: float, today: date) -> list[DayLine]`, mapping each name to its model id and host (the slug's provider part) and OpenRouter's `provider_name` to the same host in lower case.
  - `@dataclass Ranked(label: str, calls: int, spend_usd: float)`; `top_roles(rows, models, start, end) -> list[Ranked]` (roles only); `top_models(rows, models, start, end) -> list[Ranked]` (label `<model>@<host>`, every name that uses it counted).
  - `@dataclass UsageTable(roles: list[…], experiments: list[…], keys: list[…])` with calls, tokens in, tokens out and spend per period; `usage_tables(rows, models, now) -> UsageTable`.
  - `@dataclass CostSummary(...)` with spend day/week/month (from the inference key's `usage_*`), balance (`total_credits − total_usage`), key limit and remaining, the gateway's global budget, forecast, reset times and whether they agree, top roles and models, reconciliation, latest checks; `cost_summary(…) -> CostSummary`, each field `None` when its source was `Unavailable`, with the source listed in `missing`.

- [ ] **Step 1: Write tests:** `test_period_bounds_week_starts_monday` (Wednesday 2026-11-04 12:00 → week from 2026-11-02 00:00); `test_period_bounds_sunday_night` (Sunday 2026-11-08 23:59 → still the week of 2026-11-02); `test_period_bounds_ignore_local_tz` (same result with `TZ=Europe/Oslo` set via `monkeypatch` and `time.tzset()`); `test_forecast_mid_month` (15 days elapsed, $7.50 spent, 30-day month → $15.00); `test_forecast_on_the_first` (00:10 on the 1st, $0.02 → $0.60 for a 30-day month); `test_reconcile_flag_threshold` ($7.40 vs $7.42 → not flagged; $1.00 vs $1.10 → flagged at $0.10 > $0.05; $10 vs $10.40 → not flagged, 4%); `test_reconcile_days_maps_hosts`; `test_top_models_counts_role_and_experiment_together` (`chat` and `gpt-oss-120b@deepinfra` both → `gpt-oss-120b@deepinfra`); `test_summary_with_openrouter_down` (balance `None`, `missing == ["openrouter"]`, gateway figures present); `test_resets_mismatch_shown`.
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — expected PASS.
- [ ] **Step 5: Commit** `tower: cost summary, usage and reconciliation`.

### Task 9: Pages and look

**Files:**
- Create: `tower/tower/setup_view.py`, `tower/tower/templates/cost.html`, `usage.html`, `setup.html`, `log.html`, `tower/tower/templates/macros/bars.html`, `tower/tower/static/tower.css`, `tower/tower/static/htmx.min.js`, `tower/tests/test_pages.py`, `tower/tests/test_setup_view.py`
- Modify: `tower/tower/app.py`

**Interfaces:**
- Consumes: Tasks 3, 6, 7, 8.
- Produces: `GET /` (Cost, with `?period=day|week|month` for the top lists, default `month`), `GET /usage`, `GET /setup`, `GET /log`. `setup_view.build(gw, orc, settings) -> dict` with sections `models` (per name: kind, model, host and quantisation from the slug, fallbacks on or off, `zdr`, price in and out per million tokens, default `max_tokens`, and its latest price check result), `teams_and_keys` (budget, spend, reset, allowed names, rate limits), `openrouter_key`, `management_key` (days left), `gateway_settings` (each value labelled `api` or `config.yaml`), `open_webui` (non-secret `chat` environment from the mounted `docker-compose.yml`; a value that is a `${…}` reference shows as "secret, from .env"), `secrets` (tower's own five by name, `set`/`not set`). Bars are SVG from a Jinja macro `bar(value, max, marker=None)`; no JavaScript besides htmx.

- [ ] **Step 1: Write tests:** `test_cost_page_shows_figures` (fake clients → `$7.40`, `key limit $35`, `forecast` labelled as an estimate); `test_cost_page_renders_with_gateway_down` (200, the warning text naming the gateway, kill switch partial present); `test_cost_page_renders_with_openrouter_down`; `test_usage_lists_roles_and_experiments_apart`; `test_setup_open_webui_from_compose` (reads the real `docker-compose.yml` from the repo; `TASK_MODEL_EXTERNAL` shown, `WEBUI_SECRET_KEY` shown as "secret, from .env"); `test_setup_secrets_set_or_not_set`; `test_log_newest_first`; `test_no_secret_in_any_page` (render every page with secrets set to distinct markers; none appears in any response body).
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement** look B from the spec's "Look": dark warm background, a serif for headings and large numbers, a monospace for labels, an amber accent, a separate danger colour for the kill switch engaged, a failed check and a reconciliation flag; works at phone width. Vendor `htmx` 2.0.x (pinned, from its release, with its version in a comment at the top).
- [ ] **Step 4: Run** — expected PASS. Start tower locally against the fakes (`uv run uvicorn` with the test settings) and look at each page at desktop and phone width; show the owner screenshots before committing the stylesheet's final form.
- [ ] **Step 5: Commit** `tower: pages and look`.

### Task 10: Metrics and the background loop

**Files:**
- Create: `tower/tower/metrics.py`, `tower/tower/loop.py`, `tower/tests/test_metrics.py`, `tower/tests/test_loop.py`
- Modify: `tower/tower/app.py`

**Interfaces:**
- Produces: `GET /metrics` (no login) from a dedicated `CollectorRegistry` with: `rapidselector_openrouter_balance_usd`, `rapidselector_key_limit_usd`, `rapidselector_key_limit_remaining_usd`, `rapidselector_key_usage_usd{period="day|week|month"}`, `rapidselector_reconciliation_diff_usd`, `rapidselector_reconciliation_flagged`, `rapidselector_kill_switch_level` (0, 1, 2; −1 when unknown), `rapidselector_price_check_ok`, `rapidselector_price_check_last_run_timestamp_seconds`, `rapidselector_smoke_test_ok`, `rapidselector_management_key_expires_timestamp_seconds`, `rapidselector_upstream_ok{source="gateway|openrouter"}`. `update_metrics(summary, switch, latest_price, latest_smoke, expiry) -> None`. `loop.tick(now, gw, orc, settings) -> None`: update metrics, `enforce`, a `balance` log entry if none in the last hour, the price check if none since the latest 06:30 UTC. `start_loop(app)` runs `tick` every 60 s in a worker thread; an exception in a tick is logged without secrets and the loop carries on.

- [ ] **Step 1: Write tests:** `test_metrics_names_and_values`; `test_metrics_unknown_switch_is_minus_one`; `test_metrics_no_secret`; `test_tick_runs_price_check_once_after_0630` (05:00 → no; 06:31 → yes; 06:32 → no); `test_tick_snapshots_balance_hourly`; `test_tick_survives_unavailable` (both clients down → no exception, `upstream_ok` 0 for both).
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — expected PASS.
- [ ] **Step 5: Commit** `tower: metrics and background loop`.

### Task 11: OpenRouter's management routes in the fake upstream

**Files:**
- Modify: `tests/fakes/upstream.py`, `tests/fakes.bats`, `tests/helpers.bash`, `tests/compose.test.yml`

**Interfaces:**
- Produces, fake upstream: `GET /api/v1/keys` (`{"data": [{"hash","name","label","disabled","expires_at",…}]}`), `GET /api/v1/keys/{hash}` (`{"data": {…, "limit", "limit_remaining", "limit_reset", "usage", "usage_daily", "usage_weekly", "usage_monthly"}}`), `PATCH /api/v1/keys/{hash}` (`{"disabled": bool}`), `GET /api/v1/credits` (`{"data": {"total_credits", "total_usage"}}`), `GET /api/v1/activity?api_key_hash=` (`{"data": [ {date, model, provider_name, requests, usage, …} ]}`), `GET /api/v1/endpoints/zdr` (built from `gateway/config.yaml` at start, as `tests/checks.bats` does). All but the last need `Authorization: Bearer <FAKE_MANAGEMENT_KEY>` (environment variable, default `test-management-key`; `compose.test.yml` sets it to `${OPENROUTER_MANAGEMENT_KEY}`); otherwise 401. `POST /_openrouter` sets the state (keys, credits, activity, `fail: "keys"|"credits"|…` to answer 500). **While the inference key is disabled, `/v1/chat/completions` answers 401** with OpenRouter's body for a disabled key, so level 2 can be seen to stop calls. Helpers `openrouter_state <json>`, `openrouter_requests`. `compose.test.yml` gives tower `TOWER_GATEWAY_URL=http://gateway:4000` and `OPENROUTER_API_BASE_URL=http://fake-upstream:8000/api/v1`, and seeds the fake's inference key under the name `rapidselector-gateway`.
- Shapes follow `provider-facts.md` (management API, 2026-11-05); where the docs leave a field out, the fake leaves it out too.

- [ ] **Step 1: Write tests** in `tests/fakes.bats`: `fake openrouter lists keys and needs the management key`; `fake openrouter disables a key and chat calls get 401`; `fake openrouter fails on demand`; `fake openrouter zdr list matches the config`.
- [ ] **Step 2: Run** — expected FAIL.
- [ ] **Step 3: Implement** with the standard library only.
- [ ] **Step 4: Run** `tests/run.sh tests/fakes.bats` — expected PASS.
- [ ] **Step 5: Commit** `test: fake OpenRouter management routes`.

### Task 12: Tower at level 1

**Files:**
- Create: `tests/tower.bats`

**Interfaces:**
- Consumes: the whole stack with tower (`stack_up`, `run_setup_keys`), Task 11's helpers. Helper `tower_login` (stores the cookie in `$BATS_TEST_TMPDIR`), `tower_post <path> [form…]`.

- [ ] **Step 1: Write tests:** `tower is healthy and needs a login`; `level 1 blocks node-red and chat but not tower` (calls with `KEY_NODE_RED` and `KEY_CHAT` refused, tower's pages still load); `a key created while level 1 is engaged is blocked within 70 seconds`; `releasing level 1 unblocks only what tower blocked` (block `chat` by hand first through the master key; after release, `chat` is still blocked and shown as outside tower); `level 2 disables the key at the fake and chat calls fail`, then `release level 2 leaves level 1 engaged`; `a failed read-back shows the state as unknown` (`openrouter_state '{"fail":"keys"}'`); `the price check passes against the fake list and fails after a price change`; `reconciliation is flagged when the fake's usage differs by more than the threshold`; `no secret value in any page, /metrics or tower's container log` (grep every value from the test env file); `metrics report the kill switch level`; `backup command gives a valid database` (`docker exec rapidselector-tower python -m tower.backup | sqlite3 /dev/stdin 'PRAGMA integrity_check'` or the equivalent in Python on the host).
- [ ] **Step 2: Run** `tests/run.sh tests/tower.bats` — fix what fails in the tower code, not in the tests' expectations, unless a test assumed something Task 2 showed false.
- [ ] **Step 3: Run the whole level 1 suite** `tests/run.sh` — every file passes (the existing files must not be affected by tower's new secrets beyond the test env file).
- [ ] **Step 4: Commit** `test: tower at level 1`.

### Task 13: README, test procedure and the `production` repository

**Files:**
- Modify: `README.md` (address table with tower on 4020; first start: the four secrets, `TOWER_GATEWAY_KEY` starting with `sk-`, the management key with a one-year expiry and how to replace it; `./rapidselector.sh up` builds tower; the kill switch, and that the manual ways in the README still work without tower; backup of `tower.db`)
- Create: `docs/test-procedures/tower-1a.md`
- In `production` (a separate commit there, pushed only with the owner's permission): `backup-orchestrator/remote/rapidselector-export.sh` gains the word `tower` (`exec docker exec rapidselector-tower python -m tower.backup`), with a test in `tests/rapidselector_jobs.bats`; `backup-orchestrator/jobs/rapidselector-tower.sh`; a `jobs.conf` line `rapidselector-tower|rapidselector-tower.sh|db|1|sqlite` (min_bytes set after the first run, then the backup count 11 → 12); the Prometheus target `sandbox:4020`, path `/metrics`; `grafana/rapidselector-tower-alerts.md` describing the rules (kill switch engaged: `rapidselector_kill_switch_level > 0` for 1m; level unknown: `== -1` for 5m; price check failed: `rapidselector_price_check_ok == 0`; price check stale: older than 26 h; reconciliation gap: `rapidselector_reconciliation_flagged == 1` for 24h; balance low: `rapidselector_openrouter_balance_usd < 2`; management key expiring: within 30 days; tower down: `up == 0` for 5m) and the dashboard panels, for a Claude Code session in `production` with the Grafana MCP to create.

`tower-1a.md` lists, one step at a time with cost: adding the four secrets to secrets-service; creating the management key (one year) and noting its date; `./rapidselector.sh run-script scripts/setup-keys.sh`; `./rapidselector.sh up`; logging in; Cost figures against OpenRouter's dashboard (balance, key limit, usage); the price check from the button; the smoke test with its estimate shown first (cost under $0.01); level 1 stopping a Node-RED call and a chat message, then released; **level 2 disabling the real key, how fast a call is then refused (spec: not documented), and re-enabling it**; that the management key appears with its expiry (or setting `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT`); the backup job's first run; the alerts created.

- [ ] **Step 1: Write the README sections and the test procedure.**
- [ ] **Step 2: Make the `production` changes**, test first for the export word (`npx --yes bats@1.11.0 backup-orchestrator/tests`, all pass).
- [ ] **Step 3: Run** `tests/run.sh tests/stack.bats` (README address table and Compose agree, if such a check exists; otherwise read them side by side).
- [ ] **Step 4: Commit** in rapid-selector `docs: tower part 1a, README and test procedure`; in `production`, commit and ask the owner before pushing.
