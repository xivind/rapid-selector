# Decisions and open questions

Open questions move to "Decided" when settled, with date and reason. Facts that a question depends on are in `provider-facts.md`.

## Decided

### 2026-11-02: Monthly budget
**400 NOK** a month (roughly 35–40 USD depending on the exchange rate), including OpenRouter's 5.5% fee, which is charged when buying credits.

### 2026-11-03: The monthly cap is the key limit, not the top-up
Unspent credit carries over, so the maximum possible loss is the whole balance. The balance is kept small, and the monthly cap is the inference key's credit limit with a monthly reset. Reason: with manual top-ups, a monthly top-up of 400 NOK does not cap monthly spend.

### 2026-11-03: Tower login
`tower` gets a login with a single password set in `.env`. Plain HTTP on the LAN is accepted. Reason: keep it simple; the LAN is not fully trusted, since any device on it could reach tower and its kill switch.

### 2026-11-03: Log analysis is later
Log analysis is not implemented now. What is needed now is that models can be called through the gateway's HTTP API with a virtual key. When log analysis is built, what is sent may need cleaning of personal data first. Reason: logs can hold IP addresses, MAC addresses, usernames and household routines.

### 2026-11-03: Evaluate existing arena tools before building
Before building the arena and benchmarking in `tower`, evaluate Open WebUI's built-in arena and promptfoo. Reason: reuse before build.

### 2026-11-03: CLAUDE.md is generic and stable
`CLAUDE.md` holds only what is always true, not tied to phases. Requirements, roadmap, decisions and dated facts live in `docs/`. Reason: a CLAUDE.md that keeps changing is a moving target for every session.

## Open

### Settle during design or phase 0

1. **Is the loss really capped?** Test with a very small balance, since this costs a little real money. The docs mention negative balances without saying how far one can go (`provider-facts.md`). The test needs a cost ceiling agreed in advance.
2. **How do key limits behave in practice?** The docs now confirm a monthly reset option and a 402 error when the key's limit is reached (`provider-facts.md`). Still to test: that the limit actually stops calls, and how a request that crosses the limit is charged.
3. **How does LiteLLM record OpenRouter spend?** Either explicit prices in the gateway config, or the actual cost from OpenRouter's response if LiteLLM reads it. Also confirm that LiteLLM passes on the host pin and zero data retention settings.
4. **Is the Standard plan free of any subscription fee?** The owner wants pay as you go with no flat rates, and only the 5.5% credit fee has been seen so far.
5. **Do the wanted models have zero data retention hosts?** For example, `lfm-2.5-2.6b` had none listed.
6. **Management key expiry.** OpenRouter recommends an expiry date on every management key, and it cannot be changed after creation. Decide whether to use one, and how `tower` gets a new key before the old one expires.
7. **Does the stack fit on the Pi?** Check that LiteLLM's images (including the Postgres variant) exist for arm64, and how much RAM LiteLLM and Open WebUI need. Open WebUI's local embedding and RAG features may need to be turned off.
8. **Is LiteLLM's spend log retention free or an Enterprise feature?**
9. **Which Open WebUI features call outside services** (web search, image generation, default OpenAI and Ollama connections), and how are they turned off?
10. **`tower` stack.** The owner chooses, after options and a recommendation are presented.

### Settle later

- **Is an asynchronous layer such as MQTT needed at all?** Decide in phase 3, based on the log analysis use case.

### Proposals not yet decided

11. **One source of truth for the allowlist.** Each entry is a model, a host, a price, a zero data retention setting and maybe a quantisation. A single file (e.g. `models.yaml`) could generate the LiteLLM config and drive the spend tests.
12. **Price drift.** If a pinned host changes its price, recorded spend goes wrong. Reconciliation only catches the total, since there is one inference key. `tower` could compare configured prices with OpenRouter's per-host prices.
13. **`max_tokens` for reasoning models.** Hidden reasoning counts against `max_tokens` and is billed as output. A low default can give empty answers. The default may need to be set per model, along with a reasoning-effort setting.
14. **Back up the secrets.** A Postgres backup is useless without LiteLLM's salt key. The backup plan must cover `.env` (or at least the master key and salt key), stored safely and separately.
15. **DHCP reservation.** Ports are bound to the Pi's LAN address, so the address must not change. The README should say to reserve it on the router.
