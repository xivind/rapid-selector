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
- **Management keys:** "cannot be used to make API calls to OpenRouter's completion endpoints". A leaked one "could create, edit and delete the API keys in your account". OpenRouter recommends an expiry date on every management key; the expiry cannot be changed after creation, and an expired key gets `401 API key expired`.

## LiteLLM

### 2026-11-02 (owner) and 2026-11-03 (checked)
- LiteLLM's price map (`model_prices_and_context_window.json` on the `main` branch) has no `openrouter/` entries: 0 of 4,561 entries on 2026-11-03. OpenRouter models therefore need explicit prices in the gateway config, or spend is recorded at 0.

## Model range

### 2026-11-02 (owner)
All sizes are reached through OpenRouter.
- **Smallest:** `llama-3.2-1b-instruct` (1B, served by Cloudflare), then a 1.8B translation model. General-purpose choices stay scarce until 3B.
- **Largest:** `qwen3.8-2.4t-a95b` (2.4T).
- **Same model on several hosts:** `gpt-oss-120b` has over 20, so hosts can be compared directly.
- **Zero data retention:** `lfm-2.5-2.6b` had no zero data retention host listed.
