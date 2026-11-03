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

### 2026-11-03: Overall design
Agreed section by section and written in `superpowers/specs/2026-11-03-rapid-selector-overall-design.md`. The decisions in it:

- **Permanent use, not only a lab.** rapid-selector is also a permanent part of the home infrastructure, used from Node-RED and apps. Tasks: summarising and interpreting text, analysing logs and machine data, code and scripts, classifying and extracting structure, general chat; more will come.
- **Models are an enhancement.** Every flow must work without an answer, and the owner is told when calls fail. No automatic fallback to another model or host for now.
- **Fixed shares of the budget.** Permanent use and experiments each get their own share (LiteLLM teams `permanent` and `experiments`). Experiments can never use the permanent share.
- **Grafana watches, tower acts** (approach 1 of 3). Grafana shows operations over time and sends the alerts, through the existing email contact point. Tower publishes OpenRouter's balance, key limit and reconciliation as metrics, and has the kill switch, the cost summary and later the arena. The cost summary is always in tower, with or without Grafana.
- **The core works on its own; integrations are optional.** Prometheus and Grafana, secrets-service, backup-orchestrator and Loki are switched on in configuration. Reason: others may use the repository.
- **Secrets are environment variables from a pluggable source:** `.env` by default, or secrets-service through `rapidselector.sh`. The owner uses secrets-service. Reason: if `home-assistant` is down, there are bigger problems than the gateway.
- **Hosts:** `sandbox` (Pi 5, 8 GB) while testing, then `webserver` (Pi 5, 16 GB) once stable.
- **Clients reach the gateway as `llm`,** a name alias on the router pointing to the current host.
- **Names are prefixed with `rapidselector`:** Compose project, containers, volumes and the images we build.
- **The allowlist is `gateway/config.yaml`,** in LiteLLM's format, with roles for permanent use and `model@host` names for experiments. Settles proposal 11.
- **Default `max_tokens` per model** in the allowlist. Settles proposal 13.
- **Price drift is caught by a reconciliation alert** in Grafana. Settles proposal 12 for now; a per-model price check can be added later.
- **Backups:** Postgres, Open WebUI's data and tower's SQLite, through backup-orchestrator jobs in the `production` repository, or by the README's fallback. The salt key is covered by secrets-service's key escrow, or by keeping `.env` safe. Settles proposal 14.
- **Fixed host addresses** through DHCP reservations, stated in the README. Settles proposal 15.
- **Tower's level of visual ambition is decided first in phase 1,** together with its stack.
- **Programmatic use is an open category.** Every new use gets its own key, calls a role, has its input checked for personal data, and is recorded here.

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
10. **`tower` stack.** The owner chooses, after options and a recommendation are presented. Phase 1, first, together with the level of visual ambition (A clean and functional, B distinctive, C experimental; see the overall design, section 11).
11. **Are LiteLLM teams available in the open-source version?** The fixed budget shares depend on them. Phase 0.
12. **Which error does LiteLLM return for an exhausted budget?** Clients must not retry it. Phase 0.
13. **Does LiteLLM's `/metrics` require auth by default?** Phase 0.
14. **What does LiteLLM do if the database disappears while running?** Phase 0.
15. **How do container logs reach Loki?** Phase 0.
16. **How is the empty-balance case tested?** With a tiny balance before the first real top-up, or by relying on the key limit and the documentation. Phase 0.
17. **Can tower use an admin key other than LiteLLM's master key?** Phase 1.
18. **Which OpenRouter endpoint gives the inference key's limit and usage to the management key?** Phase 1.
19. **Node-RED name resolution** (`production` repository, any time). Node-RED uses `--add-host` for every name. Hypothesis: Docker falls back to public DNS because the host's resolver is a local address, and pointing the container at the router (`--dns`) would fix it. Check `/etc/resolv.conf` on `messagebroker` and inside the container. Until fixed, Node-RED needs `--add-host` for `llm`.

### Settle later

- **Is an asynchronous layer such as MQTT needed at all?** Decided per use case, from its own needs (phase 3 and later).
