# rapid-selector: overall design

Date: 2026-11-03. Status: approved by the owner on 2026-11-03. **Since 2026-11-08, `tower` is dropped** and replaced by operator scripts (`2026-11-08-scripts-instead-of-tower-design.md`, `CLAUDE.md`); what this design says about tower no longer applies.

## 1. What this spec is

The high-level design for the whole system: what cuts across phases. It is not implemented directly. Each phase gets its own spec, plan and build (`docs/superpowers/specs/`, `docs/superpowers/plans/`), starting with phase 0, and must follow this one. Where a phase spec needs to depart from it, this spec is updated first.

The rules in `CLAUDE.md` apply throughout. This spec does not repeat them.

## 2. Agreed understanding

- **Two uses, one system.** rapid-selector is both a lab for testing and comparing open-weight models and a permanent part of the owner's home infrastructure, used from Node-RED and apps.
- **Tasks:** summarising and interpreting text, analysing logs and machine data, help with code and scripts, classifying or extracting structure from short texts, and general chat. More will come.
- **Models are an enhancement.** Every flow must work without an answer from a model. The owner is told when calls fail.
- **Others may use the repository.** The core must work without the owner's home infrastructure.
- **Hosts:** `sandbox` (Raspberry Pi 5, 8 GB, 256 GB SSD) while testing, then `webserver` (Raspberry Pi 5, 16 GB) once stable.
- **Home infrastructure that already exists** (in the owner's `production` repository): Prometheus on `home-assistant:9090`, Grafana with alerting by email (contact point "Grafana Email Dispatcher"), Loki on `home-assistant:3100` with Promtail on every host, `secrets-service` on `home-assistant:8002`, and `backup-orchestrator`, which takes nightly backups to the NAS and on to Jottacloud.

## 3. Design principles

1. **The core works on its own; integrations are optional.** `gateway`, `db`, `chat` and `tower` need only Docker and secrets. Prometheus and Grafana, secrets-service, backup-orchestrator and Loki are integrations: off by default, switched on in configuration, and documented. Changes that only make sense in the owner's home (scrape targets, alert rules, backup jobs) belong in the `production` repository; rapid-selector documents how to connect.
2. **Clients call roles, not models.** A role (e.g. `summarise`) is a stable name in the gateway. The model behind it can change without touching any client.
3. **The gateway's configuration lives in git.** Models, hosts, prices and roles are defined in one file. Nothing is added through an admin UI.
4. **Secrets are environment variables.** Their names are fixed and listed in `.env.example`. Where the values come from is pluggable.
5. **One host at a time, nothing tied to it.** Everything host-specific is in `.env`.
6. **Names are prefixed with `rapidselector`:** the Compose project, containers, volumes and the images we build.

## 4. Components

```
                         ┌──────────── host (sandbox → webserver) ─────────────┐
 Open WebUI (chat) ──────┤                                                      │
 Node-RED, apps ─────────┼──► gateway (LiteLLM) ──► OpenRouter ──► upstream hosts
 tower ──────────────────┤        │                                             │
                         │       db (Postgres)                                  │
                         └──────────────────────────────────────────────────────┘
 optional:  Prometheus ◄── /metrics (gateway, tower)      Grafana ◄── Prometheus (dashboard, email alerts)
            secrets-service ──► rapidselector.sh ──► environment variables
            backup-orchestrator ◄── Postgres, Open WebUI data, tower's SQLite
            Loki ◄── container logs
```

| Service | Container | Role | Ours? |
|---|---|---|---|
| `gateway` | `rapidselector-gateway` | LiteLLM: the only way to the models. Allowlist, roles, virtual keys, budgets, spend log, `/metrics` | Configured |
| `db` | `rapidselector-db` | Postgres for LiteLLM. No published port | Configured |
| `chat` | `rapidselector-chat` | Open WebUI, with its own virtual key, connected to the gateway and nothing else | Configured |
| `tower` | `rapidselector-tower` | Cost summary, OpenRouter balance and key limit, reconciliation, kill switch, `/metrics`; later the arena and benchmarks | **Built** (image `rapidselector-tower`) |

Upstream images keep their own names and are pinned to a version. Volumes: `rapidselector_pgdata`, `rapidselector_chatdata`, `rapidselector_towerdata`, on the SSD.

## 5. Gateway: models, roles, keys and budgets

### Allowlist
`gateway/config.yaml`, in LiteLLM's own format, is the single source of truth. Models cannot be added through the admin UI. Each entry has:
- the model, pinned to one upstream host, with fallbacks off and zero data retention on;
- an explicit price from that host, as a safety net in case LiteLLM does not use the cost OpenRouter reports;
- a default `max_tokens`, set per model so that reasoning models get enough room.

### Two kinds of public names
- **Roles** for permanent use, e.g. `summarise`, `classify`, `code`, `chat`. Each points to one model on one host. Node-RED and apps use roles only.
- **Experiment names** for chat and the arena, in the form `model@host` (e.g. `gpt-oss-120b@deepinfra`), so the same model can be compared across hosts.

The first roles and models are chosen in phase 0.

### Fixed shares of the budget
Implemented with LiteLLM teams (a group of keys with a shared budget):
- **Team `permanent`:** one key per client (`node-red`, each app). Each key may use roles only, and has a low cap and a rate limit.
- **Team `experiments`:** the key for `chat`, and tower's key for the arena and benchmarks.
- LiteLLM's global budget is at most the OpenRouter key's monthly limit. The team budgets add up to at most the global budget.

LiteLLM resets a `30d` budget on the 1st of each month at 00:00 in its configured timezone (UTC by default), the same moment as OpenRouter's monthly reset. (Corrected 2026-11-03: this spec first said the two would not line up.) LiteLLM is still the soft layer; the OpenRouter key limit is the actual monthly cap.

### Background calls
Open WebUI's own model calls (titles, tags, suggestions) are turned off or sent to the cheapest role. Chosen in phase 0.

### Keys and teams
Created once through LiteLLM's admin UI or API, following the README. They live in Postgres and move with it.

## 6. Interfaces

### Clients → gateway
- OpenAI-compatible API at `http://llm:<port>/v1/chat/completions`, with the client's own virtual key and a role in `model`.
- `llm` is a name alias on the owner's router, pointing to the current host. Other users use their own host name.
- `chat` reaches the gateway inside the Compose network (`http://gateway:4000`).

### tower → gateway (LiteLLM's API)
- Reads spend per key, team and model, and budget status.
- Blocks and unblocks all virtual keys (kill switch level 1). Uses its own admin key rather than the master key, if LiteLLM allows it.
- Uses a separate key in team `experiments` for the arena.

### tower → OpenRouter (management key)
- Reads the account balance (`GET /api/v1/credits`).
- Reads the inference key's limit, remaining limit and usage through the key-management API.
- Disables and re-enables the inference key (`PATCH /api/v1/keys/{hash}`, kill switch level 2).

### Metrics (optional integration)
- Prometheus scrapes LiteLLM's `/metrics` and tower's `/metrics`.
- Tower's metrics share the prefix `rapidselector_`, e.g. `rapidselector_openrouter_balance_usd`, `rapidselector_key_limit_remaining_usd`, `rapidselector_reconciliation_diff_usd`, `rapidselector_kill_switch_engaged`.
- Metrics carry key aliases and amounts, never secrets, and have no login, like `node_exporter` on the owner's hosts.

### Ports and access
- Published, bound to the host's LAN address from `.env`: the gateway (API and admin UI), `chat` and `tower`. Postgres publishes nothing.
- Tower: one password from the environment. LiteLLM's admin UI and Open WebUI use their own logins.

### Logs
Every service logs to stdout. Shipping container logs to Loki is an optional integration.

### Secrets
The environment variables in `.env.example`, e.g. `RAPIDSELECTOR_OPENROUTER_KEY` (deliberately not `OPENROUTER_API_KEY`, which LiteLLM's `/openrouter` pass-through would pick up; see the phase 0 spec), `OPENROUTER_MANAGEMENT_KEY`, `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, Postgres credentials, Open WebUI's key and secret, and tower's password and keys. Two sources:
- **`.env`** (the default).
- **secrets-service:** `rapidselector.sh` fetches each secret before running Compose and passes it on as an environment variable, following the shell pattern in the `production` repository's `secrets-service/CLAUDE.md`. Only the secrets-service client token is stored on the host.

The Compose file requires each secret (`${NAME:?missing}`), so Compose refuses to run without it. Tower reads environment variables only and has no dependency on secrets-service.

Accepted trade-off: secret values are visible to anyone with Docker access on the host (`docker inspect`), as with the owner's existing `docker run -e` pattern.

## 7. Failure handling, warnings and the kill switch

### Clients
- A failed call skips that step and is logged.
- Recommended behaviour, documented in the README: a fixed timeout, at most one retry on a timeout or 5xx, and no retry on budget or limit errors.
- No automatic fallback to another model or host.

### Warnings (Grafana integration)
Alert rules live in the `production` repository and are sent by the existing email contact point:
- a team's budget share, or the global budget, running low (e.g. 20% and 10% left);
- OpenRouter balance or key limit below a threshold;
- failure rate on the permanent roles;
- gateway or tower unreachable (Prometheus target down);
- reconciliation drift above a threshold, which also catches drift between configured and actual prices;
- kill switch engaged.

Without Grafana, the state is visible in tower's cost summary only.

### Kill switch
- **Level 1:** block all virtual keys in LiteLLM. Quick to reverse.
- **Level 2:** disable the OpenRouter inference key. This stops everything.
- Tower shows the active level. Releasing it is a deliberate action, and every change is logged.
- If tower is down, the README gives two manual ways: disable the key in OpenRouter's dashboard, or stop `rapidselector-gateway`.

### Start-up safety
- The gateway does not start without its secrets, and waits for `db` to be healthy. Without a database, LiteLLM's budgets do not block anything.
- What happens if the database disappears while running is tested in phase 0.

## 8. Operations

### `rapidselector.sh <command>`
- Loads secrets from the configured source, then runs Compose: `up`, `down`, `logs`, `ps`, `update`.
- Needed for every command, because Compose checks the required variables on every command. Users with `.env` alone can also run `docker compose` directly.
- The README explains the commands assuming no Compose experience.

### Updates
- Image versions are pinned in the Compose file and changed by a commit.
- An update is `git pull` then `./rapidselector.sh update`.
- Before upgrading LiteLLM or Open WebUI: read the release notes, take a backup, and run the smoke test afterwards.

### Smoke test
`scripts/smoke-test.sh` sends one cheap call per role with a test key. It checks that each call is answered, that recorded spend is above zero, and that a model outside the allowlist is refused. It is run after every update and move, and is part of phase 0's test procedure. It costs a little real money; the README says roughly how much.

### Running
- Restart policy `unless-stopped`.
- Memory limits per container are set from measurements on `sandbox` in phase 0.
- Spend log retention is set in LiteLLM, or by another means if that setting is not available in the open-source version.

### Backups
- **What:** Postgres (keys, budgets, spend), Open WebUI's data (admin account, settings, chats) and tower's SQLite.
- **With backup-orchestrator:** jobs in the `production` repository, streamed over SSH with a forced command, following its Node-RED job.
- **Without it:** the README shows `pg_dump` and a copy of the volumes.
- **Secrets:** with secrets-service they are covered by its key escrow. With `.env`, the README warns that `.env` must be kept safe, since a backup cannot be used without the salt key.

### Moving `sandbox` → `webserver`
A written procedure:
1. Back up on `sandbox` and stop the services.
2. Clone the repository on `webserver`, use the same secrets, and restore the data.
3. Start, and run the smoke test.
4. Point `llm` at `webserver`.
5. Update Node-RED's host entry if it is still needed.
6. Update the Prometheus target and the backup jobs in the `production` repository.

The restore is rehearsed on `sandbox` first: restore into a fresh setup and check that an existing key still works.

### Fixed addresses
The hosts keep their LAN addresses (a DHCP reservation on the router), because ports are bound to them and `llm` points to them.

## 9. Testing

Each step in a phase plan says which level verifies it.

### Level 1: in the cloud sandbox (no Pi, no money)
- **The real `gateway`, `db` and `chat` images in Compose, against a fake OpenAI-compatible upstream** that returns fixed answers with known token counts and cost. Tests check that:
  - roles and `model@host` names work;
  - a model outside the allowlist is refused;
  - a key can use only its permitted names;
  - key, team and global budgets block when used up;
  - spend is recorded above zero;
  - the gateway refuses to start without secrets or a database;
  - what happens if the database disappears while running.
- **arm64:** each pinned image's manifest is checked for `linux/arm64` without pulling it.
- **tower:** test-driven development with pytest. Calls to LiteLLM and OpenRouter are faked from documented example responses.
- **Scripts:** tested with bats and checked with shellcheck.
- **Not covered here:** the Pi's arm64 and memory, and OpenRouter's own behaviour (host pinning, zero data retention, 402, reported cost).

Docker runs in the cloud sandbox once the daemon is started by hand (`dockerd`), confirmed on 2026-11-03.

### Level 2: on the Pi, little or no money (run by the owner)
- `./rapidselector.sh up`: all services healthy.
- Memory measured with `docker stats`, and limits set from that.
- The smoke test against the real OpenRouter.
- The restore rehearsal before the move.

### Level 3: on the Pi, real money, agreed cost ceiling (run by the owner)
Written procedure `docs/test-procedures/phase-0.md`, with steps, expected results and a maximum cost:
- the OpenRouter key limit stops calls with 402;
- host pinning and zero data retention are honoured, checked against which host served each request;
- LiteLLM's recorded spend matches OpenRouter's, per model;
- an empty balance (open question 1). Phase 0 decides whether to test this with a tiny balance before the first real top-up, or to rely on the key limit and the documentation.

Results go in `docs/decisions.md`. Anything that needs level 2 or 3 is reported as not yet verified until the owner has run it.

## 10. Phases

Each phase gets its own spec, plan and build, and must work on its own before the next starts.

### Phase 0: Foundation (on `sandbox`)
- `gateway`, `db` and `chat`.
- `gateway/config.yaml` with the first roles and `model@host` names.
- Teams `permanent` and `experiments`, with keys for Node-RED, `chat` and a test key.
- `rapidselector.sh` with both secret sources.
- The smoke test, the level 1 test setup, the README, and the level 2 and 3 procedure.
- LiteLLM's `/metrics` switched on.
- In the `production` repository: a Prometheus target, Grafana alerts on LiteLLM's metrics (budget shares, failure rate, target down), and backup jobs for Postgres and Open WebUI. Permanent use starts in this phase, so it needs warnings and backups from the start.
- **Done when:** level 1 passes, and the owner has run levels 2 and 3 on `sandbox`.

### Phase 1: Tower, part 1
- **First, with the owner:** the level of visual ambition (section 11) and the stack. They decide each other.
- Login, cost summary, OpenRouter balance and key limit, reconciliation, kill switch at both levels, `/metrics`.
- In the `production` repository: a backup job for tower's SQLite, the Grafana dashboard, and the remaining alerts (balance, key limit, reconciliation, kill switch engaged).

### Move to `webserver`
A separate step following the move procedure, when things are stable. Suggested after phase 1, so tower moves with the rest; the owner decides when.

### Phase 2: Arena and benchmarks
Evaluate Open WebUI's arena and promptfoo first. Build in tower only what they do not cover, likely comparing speed and cost per host, and the visualisation.

### Phase 3: Programmatic use cases
Real uses through the gateway's HTTP API (section 12), starting with log analysis.

### Phase 4: Local inference
An extra provider in the gateway. Nothing else changes.

## 11. Tower's visualisation

- **Grafana: operations over time.** Spend per day and month, failure rate, budget levels, alerts.
- **Tower: views for making decisions and comparing.**
  - the cost summary and forecast next to the kill switch;
  - reconciliation, shown as where LiteLLM and OpenRouter disagree;
  - later, the arena and benchmarks: models against each other, the same model across hosts, price against speed against quality.
- The cost summary is always in tower, with or without Grafana.
- `docs/requirements.md` requires visual quality ("visually appealing and distinctive, with creative visualisation"), and that applies to tower.

**Level of ambition: open, and the first item in phase 1.** Rough levels to discuss:
- **A. Clean and functional:** the owner's production stack (FastAPI, Jinja2, Bootstrap, Chart.js) with a well-designed look of its own.
- **B. Distinctive:** a custom visual identity and some custom visualisations on a simple stack.
- **C. Experimental:** purpose-built visualisations, e.g. D3 or canvas, and interactive views of the model landscape.

## 12. Programmatic use cases

Log analysis is the first example, not the only one. Nothing is built for future uses in advance, but every new use, whatever it is:
- gets its own virtual key in team `permanent`, with its own cap, a call limit per run and a maximum input size;
- calls a role. It uses an existing role, or a new role added in `gateway/config.yaml`, so the client's interface never changes;
- has its input checked for personal data, according to what that use sends;
- is recorded in `docs/decisions.md`: what it does, its key and its budget;
- decides from its own needs whether it needs an asynchronous layer such as MQTT.

## 13. Changes in the `production` repository

Made there, following that repository's own conventions:
- Phase 0: a Prometheus scrape target for the gateway, Grafana alert rules, and backup jobs for Postgres and Open WebUI.
- Phase 1: a scrape target for tower, a backup job for tower's SQLite, the Grafana dashboard and the remaining alerts.
- Move: targets and backup jobs pointed at `webserver`.
- Not tied to a phase: Node-RED's name resolution. Node-RED uses `--add-host` for every name today. The hypothesis is that Docker falls back to public DNS because the host's resolver is a local address; pointing the container at the router (`--dns`) may fix it. Until then, Node-RED needs `--add-host` for `llm`, updated at the move.

## 14. Open items, and where they are settled

| Item | Settled in |
|---|---|
| Tower's level of visual ambition | Phase 1, first |
| Tower's stack | Phase 1, first |
| Are LiteLLM teams available in the open-source version? | Phase 0 |
| Does LiteLLM record OpenRouter's reported cost for chat calls? | Phase 0 |
| Which error code does LiteLLM return for an exhausted budget? | Phase 0 |
| Does LiteLLM's `/metrics` require auth by default? | Phase 0 |
| What does LiteLLM do if the database disappears while running? | Phase 0 |
| Is spend log retention available in the open-source version? | Phase 0 |
| How Open WebUI's background calls are handled | Phase 0 |
| How container logs reach Loki | Phase 0 |
| How the empty-balance case is tested | Phase 0 |
| Can tower use an admin key other than the master key? | Phase 1 |
| Which OpenRouter endpoint gives the inference key's limit to the management key | Phase 1 |
| Management key expiry and how tower gets a new key | Phase 1 |
| Node-RED name resolution | `production` repository, any time |

The full list of open questions is kept in `docs/decisions.md`.
