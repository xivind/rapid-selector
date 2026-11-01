# rapid-selector

A small, self-hosted lab for testing and comparing open-weight language models through cloud providers, with hard cost control. Runs on a single Raspberry Pi 5 (8 GB RAM, 256 GB SSD) on the home network. One user, LAN access only.

The name comes from Vannevar Bush's *Rapid Selector*, the machine meant to find the right document in large volumes of microfilm. Here, the job is to find the right model. The project is a sibling of `vannevar`.

## Purpose

1. Test and compare open-weight models (speed, cost, quality) without buying expensive hardware.
2. Find out which model class is actually good enough for the owner's tasks, as input to a possible later investment in local hardware.
3. Make the models available to the rest of the home network (Node-RED, MQTT) in a controlled way.

Claude/Anthropic is and remains the primary tool. This project is a test lab, not a replacement.

## Non-negotiable principles

### 1. Cost: maximum possible loss = prepaid balance
- The only provider at the start is **OpenRouter**, with a prepaid balance and **auto top-up disabled**.
- Monthly budget: **400 NOK** (roughly 35–40 USD depending on the exchange rate).
- Three layers, in order of priority:
  1. **Hard, at the provider:** prepaid OpenRouter balance. When it is empty, the API returns 402.
  2. **Hard, at the provider:** credit limit on the OpenRouter key used by the gateway, with monthly reset.
  3. **Soft, in the gateway:** global budget in LiteLLM plus a budget per virtual key. The sum of key budgets must never exceed the global budget.
- Software budgets are secondary. No code may assume that the LiteLLM budget alone protects against overspending.
- **Allowlisted models only.** No wildcard routing (`openrouter/*`). Every model added must have known pricing in LiteLLM. A model without known pricing is recorded at cost 0 and will never trigger the budget.
- A default `max_tokens` is applied to every call that does not set one.
- **Hidden usage in Open WebUI:** Open WebUI can make its own model calls in the background (e.g. generating titles, tags, suggestions and autocomplete). These must either be disabled or pointed at the cheapest allowlisted model. Check the current settings in the documentation.
- All limits are set in USD, since both OpenRouter and LiteLLM account in USD. `tower` displays amounts in NOK using an exchange rate from `.env`, and shows that OpenRouter's monthly reset and LiteLLM's rolling budget window are not necessarily in sync.
- Anything that runs automatically (Node-RED flows, benchmark runs, bridge jobs) gets its own keys with low caps and an upper limit on the number of calls per run.

### 2. Only the gateway holds provider keys
All clients (chat, Node-RED, tower, bridge) talk to LiteLLM using their own virtual keys. No client gets the OpenRouter key, and no client calls OpenRouter directly.

One deliberate exception: `tower` holds OpenRouter's **management key**, used to read usage and to disable the inference key (kill switch). The management key cannot be used for inference, but it can manage keys, so it is treated as the most sensitive secret in the system and exists only in `tower`.

### 3. LAN only
Nothing is exposed to the internet. No port forwarding. Services bind to the LAN interface. No remote login.

### 4. No work data, no health data
The system must never be used for work-related content or personal data. Use OpenRouter's settings for providers without data retention/training where available.

### 5. Reuse before build
We assemble existing components where they exist and build only what is unique to this project. Upstream images are not forked. They are configured.

## Architecture

```
 Open WebUI ─┐
 Node-RED  ──┼──► LiteLLM (gateway) ──► OpenRouter
 tower     ──┤        │
 bridge    ──┘     Postgres
```

| Service | What | Built by us? |
|---|---|---|
| `gateway` | LiteLLM proxy, OpenAI-compatible API, virtual keys, budgets, spend log | No, configured |
| `db` | Postgres for LiteLLM (required for virtual keys and budgets) | No |
| `chat` | Open WebUI, connected to the gateway with its own key | No, configured |
| `tower` | Control tower: usage, balance, kill switch, arena, visualisation | **Yes** |
| `bridge` | MQTT bridge for asynchronous jobs (phase 3) | **Yes** |

Later, a local inference box can be added as an additional provider in the gateway. No other part of the system should need to change for that.

### `tower` (control tower)
- Stack: Python/FastAPI, SQLite for its own data, vanilla JS frontend. Visualisation library to be chosen in the design phase.
- Reads LiteLLM data **through LiteLLM's API**, not directly from Postgres. The Prisma schema is LiteLLM's internal business.
- Own data in SQLite: benchmark runs, arena ratings, balance snapshots.
- Reconciliation: compare LiteLLM's recorded spend with OpenRouter's actual usage (`GET /api/v1/key` returns, among other things, the remaining limit). Discrepancies must be clearly visible.
- **Kill switch** at two levels: (a) block all virtual keys in LiteLLM, (b) disable the OpenRouter key via OpenRouter's management API. Level (b) is what actually stops everything.
- The visualisation should be beautiful and creative, but the cost picture must always be readable at a glance: spent today, this month, remaining balance, forecast.

### Arena and benchmarking
- Same prompt to several models side by side. Measure time to first token, tokens/second, total time, tokens in/out and cost.
- Blind quality rating: model names stay hidden until the owner has rated.
- Prompt suites are built from the owner's actual task types, not generic benchmarks.
- **Methodological caveat:** a measurement measures the whole chain (model, upstream provider, load, network). Pin the upstream provider in OpenRouter when comparing speed, repeat measurements, and store timestamp and upstream provider with every result.
- Every benchmark run shows its estimated cost before starting and requires confirmation.

### `bridge` (phase 3)
Asynchronous contract over MQTT (existing broker on the home network): a request is published on one topic with a correlation ID, and the response is published on a reply topic with the same ID. First use case is log analysis. The contract (topics, payload format, error handling, max size) is designed before any code is written.

## Platform and operations

- **Target:** Raspberry Pi 5, 8 GB RAM, arm64, Docker with the Compose v2 plugin (`docker compose`, not the deprecated `docker-compose`). All images must be available for `linux/arm64`. Our own images must be buildable for arm64.
- The owner has not used Compose before. The README must explain the few commands needed (up, down, logs, update) and assume no prior knowledge.
- Published ports must be bound explicitly to the Pi's LAN address from `.env`, never to `0.0.0.0`. Docker writes its own iptables rules and bypasses common firewall rules such as ufw, so the firewall alone is not enough.
- Services with a UI or API that the owner or the home network must reach (`chat`, `gateway` with admin UI and API, `tower`) are published on fixed ports defined in `.env`. The README must include a table of addresses and ports.
- Postgres publishes no port at all. Only services on the Compose network can reach it.
- No custom networks and no `network_mode: host`. Use Compose's automatic default network, where services find each other by service name (`gateway`, `db`). Clients outside the project (Node-RED, the MQTT broker) reach the services via the Pi's LAN address and published ports.
- **Development** happens in a cloud sandbox (amd64) with no access to the Pi. Make no assumptions about the home network. Everything specific to the home network (IPs, MQTT broker, Node-RED address) goes in `.env`.
- Set memory limits per container. Postgres and volumes live on the SSD.
- Pin image versions. No `latest`.
- Set a retention period for LiteLLM's spend log so the database does not grow without bound.
- Secrets in `.env` (never committed, listed in `.gitignore`). `.env.example` is kept up to date.
- LiteLLM's master key and salt key are generated at setup. The salt key must never be changed after provider keys have been stored, or they become unreadable. The README must state this clearly.
- Open WebUI: the owner creates the admin account on first start, then new sign-ups are disabled.
- Use healthchecks so that `gateway` waits until `db` is ready.
- Backup: the README must describe how Postgres data (keys, budgets, spend history) and `tower`'s SQLite file are backed up to the NAS on the home network. The backup target is set in `.env`.

## Repo structure (target)

```
rapid-selector/
├── CLAUDE.md
├── README.md
├── docker-compose.yml
├── .env.example
├── gateway/        # LiteLLM config
├── chat/           # Open WebUI config (if needed)
├── tower/          # control tower (our code)
├── bridge/         # MQTT bridge (phase 3)
└── docs/           # design and plans
```

## Phases

0. **Foundation:** Compose with `gateway`, `db` and `chat`. OpenRouter as the only provider, a few allowlisted models, global budget and virtual keys for `chat` and Node-RED. Verify that the budget limits actually stop calls.
1. **Control tower, part 1:** usage, balance, reconciliation and kill switch.
2. **Control tower, part 2:** arena and benchmarking with visualisation.
3. **Bridge:** MQTT-based asynchronous contract, first use case log analysis.
4. **Later:** local inference box as an additional provider.

Each phase must be usable on its own. Do not start a phase until the previous one works on the Pi.

## Way of working

- Superpowers skills are used: brainstorming before design, written plans before code, test-driven development for our own code, verification before anything is reported as done.
- Everything in English: code, comments, commit messages, documentation and conversation.
- When something depends on how LiteLLM, Open WebUI or OpenRouter work *now*: check the current documentation, not memory. These projects change quickly.
- Anything that can cost money (new models, benchmark runs, changed budgets) must be flagged explicitly to the owner.
