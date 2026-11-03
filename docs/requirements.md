# Requirements

What each service must do. The principles in `CLAUDE.md` apply to all of them. Open questions and decisions are in `decisions.md`.

## `gateway` (LiteLLM)

- Only allowlisted models, each pinned to one upstream host with fallbacks off and zero data retention on (`CLAUDE.md`, principles 1 and 4).
- Each model has an explicit price, the pinned host's price, so recorded spend is correct and non-zero. A test confirms the recorded spend for each model.
- A default `max_tokens` for every call that does not set one.
- A global budget plus a budget per virtual key. The sum of key budgets never exceeds the global budget.
- Virtual keys at least for `chat`, Node-RED and `tower`. Automated clients get low caps.
- Spend log with a retention period.

## `chat` (Open WebUI)

- Connected to the gateway with its own virtual key, and to nothing else.
- The owner creates the admin account on first start. New sign-ups are then disabled.
- Background model calls (titles, tags, suggestions, autocomplete) are disabled or pointed at the cheapest allowlisted model. Check the current settings in the documentation.

## `tower` (control tower)

### Access
- Login with a single password set in `.env`. Plain HTTP on the LAN is accepted.
- Holds OpenRouter's management key, and is the only service that does.

### Cost picture
- Always readable at a glance: spent today, this month, remaining balance, forecast.
- Displays amounts in NOK using an exchange rate from `.env`. Limits themselves are in USD.
- Shows that OpenRouter's key limit reset and LiteLLM's budget window are not necessarily in sync.

### Reconciliation
- Compares LiteLLM's recorded spend with OpenRouter's actual usage. Discrepancies must be clearly visible.
- Sources: `GET /api/v1/key` (the key's limit, remaining limit and usage) and `GET /api/v1/credits` (total credits and total usage, requires the management key). See `provider-facts.md`.

### Kill switch
- Easy to find.
- Two levels: (a) block all virtual keys in LiteLLM, (b) disable the OpenRouter inference key via the management API (`PATCH /api/v1/keys/{hash}` with `disabled: true`). Level (b) is what actually stops everything.

### Own data
- SQLite: benchmark runs, arena ratings, balance snapshots.

### Visual quality
- **Visual quality is a core requirement, not a finishing touch.** The whole interface, including the arena and benchmark results as well as the charts, must be visually appealing and distinctive, with creative visualisation. The visual direction is agreed with the owner during design, before the interface is built.
- Clarity comes first where the two conflict. The cost picture and the kill switch must never be hard to read or find.

### Stack
- Not decided. The starting proposal is Python/FastAPI with SQLite. The frontend approach and libraries are open. The owner chooses (`CLAUDE.md`, way of working).

## Arena and benchmarking

- Same prompt to several models side by side. Measure time to first token, tokens/second, total time, tokens in/out and cost.
- Blind quality rating: model names stay hidden until the owner has rated.
- Prompt suites are built from the owner's actual task types, not generic benchmarks.
- Every benchmark run shows its estimated cost before starting and requires confirmation.
- **Methodological caveat:** a measurement measures the whole chain (model, upstream host, OpenRouter, gateway, load, network). Pin the upstream host when comparing speed, repeat measurements, and store timestamp, host and quantisation with every result. Quantisation varies between hosts, so the same model name is not always the same model. Check which host actually served each request against the pin.
- Before building our own, evaluate existing tools such as Open WebUI's arena and promptfoo (`roadmap.md`, phase 2).

## Programmatic access

- The gateway's OpenAI-compatible HTTP API is the default. A Docker app uses any OpenAI-compatible client with the gateway's address and its own virtual key. Node-RED uses its HTTP request node. No extra service is needed.
- Every automated client has an upper limit on calls per run and on input size.
- Input from automated sources, such as logs, is checked for personal data before it is sent (`CLAUDE.md`, principle 4).
- **MQTT is not decided.** An asynchronous layer is only added if a real use case needs it, for example a job that outlasts HTTP timeouts or a device that can only use MQTT. Try a Node-RED flow first (MQTT in, HTTP request to the gateway, MQTT out), since that needs no code of our own.
- A custom `bridge` service is the last resort. If one is built, its contract (topics, payload format, correlation IDs, error handling, max size) is designed before any code is written, and it uses its own virtual key like any other client.
