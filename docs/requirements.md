# Requirements

What each service must do. The principles in `CLAUDE.md` apply to all of them. How the services fit together is in `superpowers/specs/2026-11-03-rapid-selector-overall-design.md`. Open questions and decisions are in `decisions.md`.

## General

- The core (`gateway`, `db`, `chat`, `tower`) works with only Docker and secrets. Prometheus and Grafana, secrets-service, backup-orchestrator and Loki are optional integrations, off by default, switched on in configuration and documented.
- Secrets are environment variables with fixed names, listed in `.env.example`. They come from `.env` or from secrets-service, through `rapidselector.sh`. The Compose file refuses to run without them.
- The Compose project, containers, volumes and the images we build are prefixed `rapidselector`.
- Everything host-specific is in `.env`, so the system can move between hosts.
- Backed up: Postgres, Open WebUI's data and tower's SQLite, through backup-orchestrator or by the README's fallback.

## `gateway` (LiteLLM)

- The allowlist is `gateway/config.yaml`. Models cannot be added through the admin UI.
- Every model is pinned to one upstream host, with fallbacks off and zero data retention on (`CLAUDE.md`, principles 1 and 4).
- Every model has an explicit price, the pinned host's price, so recorded spend is correct and non-zero. A test confirms the recorded spend for each model.
- Every model has a default `max_tokens` for calls that do not set one, large enough for reasoning models.
- Two kinds of public names: **roles** for permanent use (e.g. `summarise`, `classify`, `code`, `chat`), each pointing to one model on one host, and **experiment names** in the form `model@host`.
- Teams `permanent` and `experiments`, each with its own budget share. The team budgets add up to no more than LiteLLM's global budget, which is no more than the OpenRouter key's monthly limit.
- Team `permanent`: one key per client (Node-RED, each app), allowed roles only, with a low cap and a rate limit. Team `experiments`: keys for `chat` and for tower's arena.
- `/metrics` for Prometheus.
- Does not start without its secrets, and waits for `db` to be healthy.
- Spend log with a retention period.

## `chat` (Open WebUI)

- Connected to the gateway with its own virtual key in team `experiments`, and to nothing else.
- The owner creates the admin account on first start. New sign-ups are then disabled.
- Background model calls (titles, tags, suggestions, autocomplete) are disabled or pointed at the cheapest role. Check the current settings in the documentation.

## `tower` (control tower)

### Access
- Login with a single password from the environment. Plain HTTP on the LAN is accepted.
- Holds OpenRouter's management key, and is the only service that does.

### Cost summary
- Always in tower, with or without Grafana: spent today, this month, remaining balance, forecast, readable at a glance and placed next to the kill switch.
- Displays amounts in NOK using an exchange rate from `.env`. Limits themselves are in USD.
- Shows when OpenRouter's key limit and LiteLLM's budgets next reset. Both are set to reset on the 1st of the month at 00:00 UTC, and a mismatch must be visible.
- History over time and alerts are in Grafana, when that integration is on.

### Reconciliation
- Compares LiteLLM's recorded spend with OpenRouter's actual usage. Discrepancies must be clearly visible.
- Sources: LiteLLM's API, and OpenRouter's `GET /api/v1/credits` and key-management API with the management key. See `provider-facts.md`.

### Kill switch
- Easy to find.
- Two levels: (1) block all virtual keys in LiteLLM, (2) disable the OpenRouter inference key via the management API (`PATCH /api/v1/keys/{hash}` with `disabled: true`). Level 2 is what actually stops everything.
- Shows which level is active. Releasing it is a deliberate action, and every change is logged.
- Tower is not the only way to stop spending: the README describes the manual ways.

### Metrics
- `/metrics` for Prometheus, prefixed `rapidselector_`: OpenRouter balance, key limit and usage, reconciliation difference, kill switch state.

### Own data
- SQLite: benchmark runs, arena ratings, balance snapshots.

### Visual quality
- **Visual quality is a core requirement, not a finishing touch.** The whole interface, including the arena and benchmark results as well as the charts, must be visually appealing and distinctive, with creative visualisation. The visual direction is agreed with the owner during design, before the interface is built.
- Tower holds the views for making decisions and comparing; Grafana holds operations over time.
- The level of ambition is decided at the start of phase 1, together with the stack.
- Clarity comes first where the two conflict. The cost summary and the kill switch must never be hard to read or find.

### Stack
- Not decided. The owner's production stack (FastAPI, Uvicorn, Jinja2, Bootstrap, Chart.js) is a strong candidate. The owner chooses (`CLAUDE.md`, way of working).

## Arena and benchmarking

- Same prompt to several models side by side. Measure time to first token, tokens/second, total time, tokens in/out and cost.
- Blind quality rating: model names stay hidden until the owner has rated.
- Prompt suites are built from the owner's actual task types, not generic benchmarks.
- Every benchmark run shows its estimated cost before starting and requires confirmation.
- **Methodological caveat:** a measurement measures the whole chain (model, upstream host, OpenRouter, gateway, load, network). Pin the upstream host when comparing speed, repeat measurements, and store timestamp, host and quantisation with every result. Quantisation varies between hosts, so the same model name is not always the same model. Check which host actually served each request against the pin.
- Before building our own, evaluate existing tools such as Open WebUI's arena and promptfoo (`roadmap.md`, phase 2).

## Programmatic access

- The gateway's OpenAI-compatible HTTP API is the default. A Docker app uses any OpenAI-compatible client with the gateway's address (`llm`) and its own virtual key. Node-RED uses its HTTP request node. No extra service is needed.
- Clients call roles, never specific models.
- Every client handles a failed call by skipping that step and logging it: a fixed timeout, at most one retry on a timeout or 5xx, and no retry on budget or limit errors.
- Every new use case, whatever it is:
  - gets its own virtual key in team `permanent`, with its own cap, a call limit per run and a maximum input size;
  - calls an existing role, or a new role added in `gateway/config.yaml`;
  - has its input checked for personal data, according to what it sends (`CLAUDE.md`, principle 4);
  - is recorded in `decisions.md`: what it does, its key and its budget.
- **MQTT is not decided.** An asynchronous layer is only added if a real use case needs it, for example a job that outlasts HTTP timeouts or a device that can only use MQTT. Try a Node-RED flow first (MQTT in, HTTP request to the gateway, MQTT out), since that needs no code of our own.
- A custom `bridge` service is the last resort. If one is built, its contract (topics, payload format, correlation IDs, error handling, max size) is designed before any code is written, and it uses its own virtual key like any other client.
