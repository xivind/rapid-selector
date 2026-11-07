# rapid-selector

A small, self-hosted gateway and lab for open-weight language models through cloud providers, with hard cost control. It is used both to test and compare models and as a permanent part of the home infrastructure. Runs on a Raspberry Pi 5 on the home network; the host is set in `.env`. One owner, LAN access only.

The name comes from Vannevar Bush's *Rapid Selector*, the machine meant to find the right document in large volumes of microfilm. Here, the job is to find the right model.

## Purpose

1. Test and compare open-weight models (speed, cost, quality) without buying expensive hardware, across the full range from very small to very large.
2. Find out which model class is actually good enough for the owner's tasks, as input to a possible later investment in local hardware.
3. Make the models available in a controlled way, as a permanent part of the home infrastructure, both interactively through chat and programmatically from Node-RED and apps in Docker containers.

Claude/Anthropic is and remains the primary tool. This project is not a replacement.

## Where things live

This file holds only what is always true: purpose, principles, architecture, operating rules and way of working. It changes rarely, and only by the owner's decision. Everything else lives in `docs/`:

| File | Contents |
|---|---|
| `docs/requirements.md` | What each service must do |
| `docs/roadmap.md` | Phases and parked options |
| `docs/decisions.md` | Open questions and decisions, with date and reason |
| `docs/provider-facts.md` | Dated observations about providers, models, prices and tool behaviour |
| `docs/superpowers/specs/` | Design specs, one per piece of work |
| `docs/superpowers/plans/` | Implementation plans, one per piece of work |

Facts about providers and tools go in `docs/provider-facts.md` with a date and a source, never in this file. Check them against the current documentation before relying on them.

## Non-negotiable principles

### 1. Cost: maximum possible loss = prepaid balance, plus a small overshoot
- The only cloud provider is **OpenRouter**, with a prepaid balance and **auto top-up disabled**. OpenRouter is a broker, so requests are served by upstream hosts.
- The maximum possible loss is the prepaid balance, plus a small overshoot below zero (D6 in `docs/decisions.md`: about $0.19), so **keep the balance small**. Unspent credit carries over, so the top-up is not a monthly cap. The monthly budget is recorded in `docs/decisions.md`.
- Limits in three layers, in order of priority:
  1. **Hard, at the provider:** the prepaid OpenRouter balance.
  2. **Hard, at the provider:** a credit limit with a monthly reset on the OpenRouter key used by the gateway. This is the actual monthly cap.
  3. **Soft, in the gateway:** global budget in LiteLLM plus a budget per virtual key. The sum of key budgets must never exceed the global budget.

  "Hard" means enforced by OpenRouter, not by our software. Neither stops at the exact cent: the key limit and the balance both overshoot a little (D1 and D6 in `docs/decisions.md`).
- Software budgets are secondary. No code may assume that the LiteLLM budget alone protects against overspending.
- A limit counts as working only once it has been tested in practice. Test results are recorded in `docs/decisions.md`.
- **Allowlisted models and hosts only.** No wildcard routing (`openrouter/*`). Every allowlist entry names both the model and its upstream host, with fallbacks turned off (`provider.order` and `allow_fallbacks: false`), so a request can never move to a more expensive host. `:free` variants are not used.
- **Every model must record correct, non-zero spend.** A model without known pricing is recorded at cost 0 and will never trigger the budget. The price must be the pinned host's price, which can differ from OpenRouter's catalog price. A test must confirm the recorded spend for each model.
- A default `max_tokens` is applied to every call that does not set one.
- **Hidden usage:** clients such as Open WebUI can make their own model calls in the background (e.g. titles, tags, suggestions, autocomplete). These must either be disabled or pointed at the cheapest allowlisted model.
- All limits are set in USD, since both OpenRouter and LiteLLM account in USD.
- Anything that runs automatically (Node-RED flows, other apps, benchmark runs) gets its own keys with low caps, an upper limit on the number of calls per run, and an upper limit on input size. `max_tokens` only limits the output, so a large input can still be expensive.

### 2. Only the gateway holds provider keys
All clients (chat, Node-RED, other apps, tower) talk to LiteLLM using their own virtual keys. No client gets a provider inference key, and no client calls a provider directly for inference.

One deliberate exception: `tower` holds OpenRouter's **management key**, used to read usage and balance and to disable the inference key (kill switch). The management key cannot be used for inference, but it can create, change and delete keys, so it is treated as the most sensitive secret in the system and exists only in `tower`.

### 3. LAN only
Nothing is exposed to the internet. No port forwarding. Services bind to the LAN interface. No remote login.

### 4. No work data, no health data
The system must never be used for work-related content or personal data. Provider privacy promises are not a reason to relax this rule. Input from automated sources, such as logs, must be checked for personal data before it is sent to a model.

Prompt logging at the provider stays off, including any opt-in that gives a discount. **Zero data retention is required by default** (`provider.zdr: true` or the account setting), which makes a request fail if no such host is available. A host without zero data retention needs an explicit decision by the owner.

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

- The core (`gateway`, `db`, `chat`, `tower`) works with only Docker and secrets. Integrations with existing infrastructure (metrics and alerting, secret stores, backup, log shipping) are optional, off by default and switched on in configuration. Changes that only make sense in one home go in that home's own repository.
- Clients call roles, stable names defined in the gateway, never specific models.
- The gateway is the only place providers are configured. Adding a provider, such as local inference, changes the gateway and nothing else.
- The gateway's OpenAI-compatible HTTP API is the default for all programmatic use.
- `tower` reads LiteLLM data through LiteLLM's API, never directly from Postgres. The Prisma schema is LiteLLM's internal business.
- `tower` is the only interface we build. Open WebUI and LiteLLM's admin UI are used with whatever settings they offer, and are never forked.

## Platform and operations

- **Target:** Raspberry Pi 5, arm64, with 8 GB of memory that the stack must fit in, Docker with the Compose v2 plugin (`docker compose`, not the deprecated `docker-compose`). All images must be available for `linux/arm64`. Our own images must be buildable for arm64.
- The owner has not used Compose before. The README must explain the few commands needed (up, down, logs, update) and assume no prior knowledge.
- Published ports must be bound explicitly to the Pi's LAN address from `.env`, never to `0.0.0.0`. Docker writes its own iptables rules and bypasses common firewall rules such as ufw, so the firewall alone is not enough.
- Services that the owner or the home network must reach are published on fixed ports defined in `.env`. The README must include a table of addresses and ports.
- Postgres publishes no port at all. Only services on the Compose network can reach it.
- No custom networks and no `network_mode: host`. Use Compose's automatic default network, where services find each other by service name. Clients outside the project reach the services via the Pi's LAN address and published ports.
- Containers have no memory limits (`docs/decisions.md`). Postgres and volumes live on the SSD.
- Pin image versions. No `latest`.
- Set a retention period for LiteLLM's spend log so the database does not grow without bound.
- Secrets are environment variables with fixed names, listed in `.env.example`, which is kept up to date. They come from `.env` (never committed, listed in `.gitignore`) or from a secret store through `rapidselector.sh`. Compose refuses to run without them.
- The Compose project, containers, volumes and the images we build are prefixed `rapidselector`.
- LiteLLM's master key and salt key are generated at setup. The salt key must never be changed after provider keys have been stored, or they become unreadable. The README must state this clearly.
- Use healthchecks so that services wait for the services they depend on.
- Backup: Postgres data (keys, budgets, spend history), Open WebUI's data and `tower`'s SQLite file are backed up, through a backup integration or the fallback described in the README. A backup is useless without the salt key, so the secrets must be kept safe as well.

## Repo structure

```
rapid-selector/
├── CLAUDE.md
├── README.md
├── docker-compose.yml
├── .env.example
├── rapidselector.sh  # loads secrets, then runs docker compose
├── scripts/        # smoke test and other operator scripts
├── gateway/        # LiteLLM config
├── chat/           # Open WebUI config (if needed)
├── tower/          # control tower (our code)
└── docs/           # requirements, roadmap, decisions, facts, specs, plans
```

## Way of working

- Superpowers skills are used: brainstorming before design, written plans before code, test-driven development for our own code, verification before anything is reported as done.
- **The owner takes part in choosing the tech stack.** Before anything is built, present the realistic options with their trade-offs and a recommendation. The owner makes the final choice, and new dependencies with a real effect on the stack are raised the same way.
- Everything in English: code, comments, commit messages, documentation and conversation.
- When something depends on how LiteLLM, Open WebUI or OpenRouter work *now*: check the current documentation, not memory. These projects change quickly. Record what was found in `docs/provider-facts.md`.
- Anything that can cost money (new models, benchmark runs, changed budgets) must be flagged explicitly to the owner.
- Decisions are recorded in `docs/decisions.md`, with date and reason.
- **Development** happens in a cloud sandbox (amd64) with no access to the Pi. Make no assumptions about the home network. Everything specific to the home network (IPs, Node-RED address) goes in `.env`. Anything that needs the Pi or real money is verified by the owner on the Pi, following a written test procedure.

## Coding principles

Adapted from Forrest Chang's four principles, based on Andrej Karpathy's observations on LLM coding. They sharpen the superpowers skills; where they overlap, the skills set the process.

- **Think before coding.** Do not assume. State assumptions explicitly. When a request can be read in more than one way, present the readings instead of picking one. Push back when a simpler approach exists. When confused, stop and ask.
- **Simplicity first.** The minimum code that solves the problem. No features beyond what was asked, and no abstractions for single-use code. If code written in this piece of work takes 200 lines and could take 50, rewrite it.
- **Surgical changes.** Touch only what the task needs, in code, config and docs alike. Do not improve adjacent code or refactor what is not broken. Match the existing style. Every changed line traces directly to the request.
- **Goal-driven execution.** Define success criteria before starting, and loop until they are verified: "fix the bug" becomes "write a test that reproduces it, then make it pass". A criterion that needs the Pi or real money cannot be verified in the sandbox: it becomes a step in the owner's test procedure, and the work is reported as not yet verified until the owner has run it.
