# rapid-selector

A small, self-hosted lab for testing and comparing open-weight language models through cloud providers, with hard cost control. Runs on a single Raspberry Pi 5 (8 GB RAM, 256 GB SSD) on the home network. One user, LAN access only.

The name comes from Vannevar Bush's *Rapid Selector*, the machine meant to find the right document in large volumes of microfilm. Here, the job is to find the right model.

## Purpose

1. Test and compare open-weight models (speed, cost, quality) without buying expensive hardware, across the full range from very small (around 1B parameters) to very large (over 1T).
2. Find out which model class is actually good enough for the owner's tasks, as input to a possible later investment in local hardware.
3. Make the models available in a controlled way, both interactively through chat and programmatically from Node-RED and apps in Docker containers, for tasks such as interpreting text and analysing logs.

Claude/Anthropic is and remains the primary tool. This project is not a replacement.

## Non-negotiable principles

### 1. Cost: maximum possible loss = prepaid balance
- The only cloud provider is **OpenRouter**, with a prepaid balance and **auto top-up disabled**. OpenRouter is a broker, so requests are served by upstream hosts such as DeepInfra.
- Monthly budget: **400 NOK** (roughly 35–40 USD depending on the exchange rate). This includes OpenRouter's 5.5% fee, which is charged when buying credits.
- Three layers, in order of priority:
  1. **Hard, at the provider:** the prepaid OpenRouter balance. The docs list a 402 error when the balance cannot cover a request, but they also mention negative balances, so a small overrun may be possible. Phase 0 must prove what actually happens (see Open questions).
  2. **Hard, at the provider:** a credit limit on the OpenRouter key used by the gateway.
  3. **Soft, in the gateway:** global budget in LiteLLM plus a budget per virtual key. The sum of key budgets must never exceed the global budget.
- Software budgets are secondary. No code may assume that the LiteLLM budget alone protects against overspending.
- **Allowlisted models and hosts only.** No wildcard routing (`openrouter/*`). Every allowlist entry names both the model and its upstream host, with fallbacks turned off (`provider.order` and `allow_fallbacks: false`), so a request can never move to a more expensive host. `:free` variants are not used.
- **Every model must record correct, non-zero spend.** A model without known pricing is recorded at cost 0 and will never trigger the budget. On 2026-11-02, LiteLLM's price map had no `openrouter/` entries, and OpenRouter's catalog price can differ from the pinned host's price: `gpt-oss-120b` was listed at $0.15/$0.60 per million tokens, while DeepInfra charged $0.037/$0.17. A test must confirm the recorded spend for each model.
- A default `max_tokens` is applied to every call that does not set one.
- **Hidden usage in Open WebUI:** Open WebUI can make its own model calls in the background (e.g. generating titles, tags, suggestions and autocomplete). These must either be disabled or pointed at the cheapest allowlisted model. Check the current settings in the documentation.
- All limits are set in USD, since both OpenRouter and LiteLLM account in USD. `tower` displays amounts in NOK using an exchange rate from `.env`, and shows that OpenRouter's limit reset and LiteLLM's rolling budget window are not necessarily in sync.
- Anything that runs automatically (Node-RED flows, other apps, benchmark runs) gets its own keys with low caps, an upper limit on the number of calls per run, and an upper limit on input size. `max_tokens` only limits the output, so a large log file can still be expensive.

### 2. Only the gateway holds provider keys
All clients (chat, Node-RED, other apps, tower) talk to LiteLLM using their own virtual keys. No client gets the OpenRouter inference key, and no client calls OpenRouter directly for inference.

One deliberate exception: `tower` holds OpenRouter's **management key**, used to read usage and balance and to disable the inference key (kill switch). The management key cannot be used for inference, but it can manage keys, so it is treated as the most sensitive secret in the system and exists only in `tower`.

### 3. LAN only
Nothing is exposed to the internet. No port forwarding. Services bind to the LAN interface. No remote login.

### 4. No work data, no health data
The system must never be used for work-related content or personal data. Provider privacy promises are not a reason to relax this rule.

OpenRouter states that it does not log prompts and responses by default, but it does store metadata such as token counts and timestamps. Prompt logging stays off, including the opt-in that gives a 1% discount. **Zero data retention is required by default** (`provider.zdr: true` or the account setting), which makes a request fail if no such host is available. A host without zero data retention needs an explicit decision by the owner.

### 5. Reuse before build
We assemble existing components where they exist and build only what is unique to this project. Upstream images are not forked. They are configured.

## Architecture

```
 Open WebUI ──┐
 Node-RED   ──┤
 other apps ──┼──► LiteLLM (gateway) ──► OpenRouter ──► upstream hosts
 tower      ──┘        │
                    Postgres
```

| Service | What | Built by us? |
|---|---|---|
| `gateway` | LiteLLM proxy, OpenAI-compatible API, virtual keys, budgets, spend log | No, configured |
| `db` | Postgres for LiteLLM (required for virtual keys and budgets) | No |
| `chat` | Open WebUI, connected to the gateway with its own key | No, configured |
| `tower` | Control tower: usage, balance, kill switch, arena, visualisation | **Yes** |

Later, a local inference box can be added as an additional provider in the gateway. No other part of the system should need to change for that.

### Model range
All sizes are reached through OpenRouter. As of 2026-11-02:
- **Smallest:** `llama-3.2-1b-instruct` (1B, served by Cloudflare), then a 1.8B translation model. General-purpose choices stay scarce until 3B.
- **Largest:** `qwen3.8-2.4t-a95b` (2.4T).
- **Same model on several hosts:** `gpt-oss-120b` has over 20, so hosts can be compared directly.

### `tower` (control tower)
- **Visual quality is a core requirement, not a finishing touch.** The whole interface, including the arena and benchmark results as well as the charts, must be visually appealing and distinctive, with creative visualisation. The visual direction is agreed with the owner during design, before the interface is built.
- Clarity comes first where the two conflict. The cost picture must always be readable at a glance (spent today, this month, remaining balance, forecast), and the kill switch must be easy to find.
- `tower` is the only interface we build. Open WebUI and LiteLLM's admin UI are used with whatever appearance settings they offer, and are never forked to change how they look.
- Stack: not decided (see Way of working). The starting proposal is Python/FastAPI with SQLite for its own data. The frontend approach and libraries, such as vanilla JS, htmx, a framework or a visualisation library, are open.
- Reads LiteLLM data **through LiteLLM's API**, not directly from Postgres. The Prisma schema is LiteLLM's internal business.
- Own data in SQLite: benchmark runs, arena ratings, balance snapshots.
- Reconciliation: compare LiteLLM's recorded spend with OpenRouter's actual usage. `GET /api/v1/key` returns the key's limit, remaining limit and usage. `GET /api/v1/credits` returns total credits and total usage, and requires the management key. Discrepancies must be clearly visible.
- **Kill switch** at two levels: (a) block all virtual keys in LiteLLM, (b) disable the OpenRouter inference key via the management API (`PATCH /api/v1/keys/{hash}` with `disabled: true`). Level (b) is what actually stops everything.

### Arena and benchmarking
- Same prompt to several models side by side. Measure time to first token, tokens/second, total time, tokens in/out and cost.
- Blind quality rating: model names stay hidden until the owner has rated.
- Prompt suites are built from the owner's actual task types, not generic benchmarks.
- **Methodological caveat:** a measurement measures the whole chain (model, upstream host, OpenRouter, load, network). Pin the upstream host when comparing speed, repeat measurements, and store timestamp, host and quantisation with every result. Quantisation varies between hosts, so the same model name is not always the same model. OpenRouter's `X-OpenRouter-Metadata: enabled` header reports which host served a request, and the result should be checked against the pin.
- Every benchmark run shows its estimated cost before starting and requires confirmation.

### Programmatic access
- **The gateway's OpenAI-compatible HTTP API is the default for all programmatic use.** A Docker app uses any OpenAI-compatible client with the gateway's address and its own virtual key. Node-RED uses its HTTP request node. No extra service is needed.
- **MQTT is not decided.** An asynchronous layer is only added if a real use case needs it, for example a job that outlasts HTTP timeouts or a device that can only use MQTT. Try a Node-RED flow first (MQTT in, HTTP request to the gateway, MQTT out), since that needs no code of our own.
- A custom `bridge` service is the last resort. If one is built, its contract (topics, payload format, correlation IDs, error handling, max size) is designed before any code is written, and it uses its own virtual key like any other client.

## Platform and operations

- **Target:** Raspberry Pi 5, 8 GB RAM, arm64, Docker with the Compose v2 plugin (`docker compose`, not the deprecated `docker-compose`). All images must be available for `linux/arm64`. Our own images must be buildable for arm64.
- The owner has not used Compose before. The README must explain the few commands needed (up, down, logs, update) and assume no prior knowledge.
- Published ports must be bound explicitly to the Pi's LAN address from `.env`, never to `0.0.0.0`. Docker writes its own iptables rules and bypasses common firewall rules such as ufw, so the firewall alone is not enough.
- Services with a UI or API that the owner or the home network must reach (`chat`, `gateway` with admin UI and API, `tower`) are published on fixed ports defined in `.env`. The README must include a table of addresses and ports.
- Postgres publishes no port at all. Only services on the Compose network can reach it.
- No custom networks and no `network_mode: host`. Use Compose's automatic default network, where services find each other by service name (`gateway`, `db`). Clients outside the project (Node-RED, other apps) reach the services via the Pi's LAN address and published ports.
- **Development** happens in a cloud sandbox (amd64) with no access to the Pi. Make no assumptions about the home network. Everything specific to the home network (IPs, Node-RED address) goes in `.env`.
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
├── bridge/         # only if phase 3 shows a need for it
└── docs/           # design and plans
```

## Phases

0. **Foundation:** Compose with `gateway`, `db` and `chat`. OpenRouter as the only provider, a few allowlisted models with pinned hosts, global budget and virtual keys for `chat` and Node-RED. Verify that the budget limits actually stop calls, both at OpenRouter and in LiteLLM.
1. **Control tower, part 1:** usage, balance, reconciliation and kill switch.
2. **Control tower, part 2:** arena and benchmarking with visualisation.
3. **Programmatic use:** first real use case (log analysis) through the gateway's HTTP API, from Node-RED or a Docker app. Decide from that experience whether an asynchronous layer is needed.
4. **Later:** local inference as an additional provider, starting with very small models on the Pi or a separate box.

Each phase must be usable on its own. Do not start a phase until the previous one works on the Pi.

### Parked options
Researched on 2026-11-02 and left out for now:
- **Very small models on the Pi:** could widen the choice below 3B and show what runs locally. RAM is the main constraint, since even Ollama's smallest Gemma 4 download (`e2b`) is 4.6 GB or more. Speed on the Pi's CPU would not predict speed on better hardware. Local models would need a deliberate exception to the non-zero spend rule, and must not be timed alongside cloud models.
- **DeepInfra directly:** two of its live text models are not on OpenRouter (`Seed-1.8` and `Seed-2.0-pro`), and going direct would avoid the fee and could measure the broker's overhead. It has weaker controls for this project: API keys are described as full-access, and no balance endpoint has been found.
- **Ollama Cloud:** no longer needed for model coverage, since models like `mistral-large-4` and `muse-spark-open` are on OpenRouter. It would use Pay as you go, never a subscription, but it has no per-key limits below Enterprise, no documented API to revoke keys, and unnamed partner hosts that cannot be pinned.

## Way of working

- Superpowers skills are used: brainstorming before design, written plans before code, test-driven development for our own code, verification before anything is reported as done.
- **The owner takes part in choosing the tech stack.** Before anything is built, present the realistic options with their trade-offs and a recommendation, covering backend and frontend frameworks, JS libraries, htmx, visualisation libraries and so on. The owner makes the final choice, and new dependencies with a real effect on the stack are raised the same way.
- Everything in English: code, comments, commit messages, documentation and conversation.
- When something depends on how LiteLLM, Open WebUI or OpenRouter work *now*: check the current documentation, not memory. These projects change quickly.
- Anything that can cost money (new models, benchmark runs, changed budgets) must be flagged explicitly to the owner.

## Open questions

Provider facts in this file were read from the providers' documentation and public catalogs on 2026-11-02. These must be settled during design or Phase 0:

1. **Is the loss really capped?** Test with a very small balance, since this costs a little real money. The docs mention negative balances without saying how far one can go.
2. **How do key limits behave?** The docs give both 402 and 403 for a key whose limit is reached, and only show a daily reset. The monthly reset this design wants is unconfirmed.
3. **How does LiteLLM record OpenRouter spend?** Either explicit prices in the gateway config, or the actual cost from OpenRouter's response if LiteLLM reads it. Also confirm that LiteLLM passes on the host pin and zero data retention settings.
4. **Is the Standard plan free of any subscription fee?** The owner wants pay as you go with no flat rates, and only the 5.5% credit fee has been seen so far.
5. **Do the wanted models have zero data retention hosts?** For example, `lfm-2.5-2.6b` had none listed.
6. **Is an asynchronous layer such as MQTT needed at all?** Decide in phase 3, based on the log analysis use case.
