# Requirements

What each service must do. The principles in `CLAUDE.md` apply to all of them. How the services fit together is in `superpowers/specs/2026-11-03-rapid-selector-overall-design.md`. Open questions and decisions are in `decisions.md`.

## General

- The core (`gateway`, `db`, `chat`) works with only Docker and secrets. Prometheus and Grafana, secrets-service, backup-orchestrator and Loki are optional integrations, off by default, switched on in configuration and documented.
- Secrets are environment variables with fixed names, listed in `.env.example`. They come from `.env` or from secrets-service, through `rapidselector.sh`. The Compose file refuses to run without them.
- The Compose project, containers, volumes and the images we build are prefixed `rapidselector`.
- Everything host-specific is in `.env`, so the system can move between hosts.
- Backed up: Postgres and Open WebUI's data, through backup-orchestrator or by the README's fallback.

## `gateway` (LiteLLM)

- The allowlist is `config/gateway.yaml`, each home's own (examples in `config/`). Models cannot be added through the admin UI.
- Every model is pinned to one upstream host, with fallbacks off and zero data retention on (`CLAUDE.md`, principles 1 and 4).
- Every model has an explicit price, the pinned host's price, so recorded spend is correct and non-zero. A test confirms the recorded spend for each model.
- Every model has a default `max_tokens` for calls that do not set one, large enough for reasoning models.
- Two kinds of public names: **roles** for permanent use (e.g. `summarise`, `classify`, `code`, `chat`), each pointing to one model on one host, and **experiment names** in the form `model@host`.
- Teams `permanent` and `experiments`, each with its own budget share. The team budgets add up to no more than LiteLLM's global budget, which is no more than the OpenRouter key's monthly limit.
- Team `permanent`: one key per client (Node-RED, each app), allowed roles only, with a low cap and a rate limit. Team `experiments`: keys for `chat` and for benchmark runs.
- `/metrics` for Prometheus.
- Does not start without its secrets, and waits for `db` to be healthy.
- Spend log with a retention period.

## `chat` (Open WebUI)

- Connected to the gateway with its own virtual key in team `experiments`, and to nothing else.
- The owner creates the admin account on first start. New sign-ups are then disabled.
- Background model calls (titles, tags, suggestions, autocomplete) are disabled or pointed at the cheapest role. Check the current settings in the documentation.

## Operator scripts

Bash with `jq`, in `scripts/`, documented in `scripts/README.md` for a person and an agent alike, and task by task in `docs/user-guide.md`. No service: each script runs when called, through `./rapidselector.sh run-script`, and exits `0` all well, `1` something needs a look, `2` a source could not be read or wrong usage.

### Status
- `status.sh`, on one screen: OpenRouter's balance, the inference key's limit, what is left and its usage today, this week and this month, a month forecast, the gateway's global and team spend against budget with their reset dates, and the management key's days left.
- Warns (exit `1`) when the balance is below $10 (OpenRouter's billing checks then slow calls, so speed comparisons are unreliable), the inference key is disabled, a budget is above 80% spent, OpenRouter's key limit and LiteLLM's budgets do not reset on the same day (both on the 1st at 00:00 UTC; a mismatch must be visible), or the management key expires within 30 days.
- All amounts in USD, as OpenRouter and LiteLLM account in USD (decided 2026-11-05).

### Reconciliation
- `reconcile.sh`: per completed UTC day (7 by default, at most 30) and per model id, LiteLLM's recorded spend against OpenRouter's activity for the inference key. A difference above $0.05 or 5% of OpenRouter's figure, whichever is larger, is flagged.
- Names sharing a model id are one line, since LiteLLM's daily table merges them (`provider-facts.md`).
- Sources: LiteLLM's API, and OpenRouter's management API with the management key, borrowed per run (`CLAUDE.md`, principle 2).

### The management key is optional
- Decided by the owner on 2026-11-08. Without it everything starts and runs, but `status.sh` and `reconcile.sh` stop with exit 3 and say why, and the Prometheus cost figures are not written. What that loses, and how to add the key later, is written out in `scripts/README.md` ("Without the management key") and pointed to from the README's first setup.

### A guarded model change
- `check-prices.sh` checks the rules of `CLAUDE.md` principles 1 and 4 on every entry in `config/gateway.yaml`, and the settings in `config/home.env` (offline), then the prices and hosts against OpenRouter's zero data retention list (online).
- `./rapidselector.sh restart gateway`, and `restart` with no service, run the rules first and refuse to restart when one is broken. A reboot or `up` still starts whatever the config holds.

### Prometheus (optional)
- `status.sh --prometheus` and `reconcile.sh --prometheus` print Prometheus text format, prefixed `rapidselector_`: balance, key limit, remaining and monthly usage, whether the key is disabled, the management key's days left, flagged lines and the largest difference, and the time of each run.
- A cron job can write them to `node_exporter`'s textfile collector, for Grafana's alerts and dashboard (README). The alert rules and dashboard belong to the home's own repository.

### Two modes
- Bare-bones: secrets in `.env`, no Prometheus; the scripts are run by hand, as `scripts/README.md` says. The management key then sits in `.env` beside the other secrets.
- Extended: secrets from secrets-service, and the Prometheus output fed to Grafana.

### Kill switch
- No script. Level 1: block the virtual keys in LiteLLM's admin UI. Level 2, which actually stops everything: disable the inference key in OpenRouter's dashboard. The README describes both.

## Arena and benchmarking

- Same prompt to several models side by side. Measure time to first token, tokens/second, total time, tokens in/out and cost.
- Blind quality rating: model names stay hidden until the owner has rated.
- Prompt suites are built from the owner's actual task types, not generic benchmarks.
- Every benchmark run shows its estimated cost before starting and requires confirmation.
- **Methodological caveat:** a measurement measures the whole chain (model, upstream host, OpenRouter, gateway, load, network). Pin the upstream host when comparing speed, repeat measurements, and store timestamp, host and quantisation with every result. Quantisation varies between hosts, so the same model name is not always the same model. Check which host actually served each request against the pin.
- Open WebUI's arena and promptfoo do this; nothing of our own is built for it (`CLAUDE.md`, architecture; `roadmap.md`, phase 2).

## Programmatic access

- The gateway's OpenAI-compatible HTTP API is the default. A Docker app uses any OpenAI-compatible client with the gateway's address (`http://<host>:4000`) and its own virtual key. Node-RED uses its HTTP request node. No extra service is needed.
- Clients call roles, never specific models.
- Every client handles a failed call by skipping that step and logging it: a fixed timeout, at most one retry on a timeout or 5xx, and no retry on budget or limit errors.
- Every new use case, whatever it is:
  - gets its own virtual key in team `permanent`, with its own cap, a call limit per run and a maximum input size;
  - calls an existing role, or a new role added in `config/gateway.yaml`;
  - has its input checked for personal data, according to what it sends (`CLAUDE.md`, principle 4);
  - is recorded in `decisions.md`: what it does, its key and its budget.
- **MQTT is not decided.** An asynchronous layer is only added if a real use case needs it, for example a job that outlasts HTTP timeouts or a device that can only use MQTT. Try a Node-RED flow first (MQTT in, HTTP request to the gateway, MQTT out), since that needs no code of our own.
- A custom `bridge` service is the last resort. If one is built, its contract (topics, payload format, correlation IDs, error handling, max size) is designed before any code is written, and it uses its own virtual key like any other client.
