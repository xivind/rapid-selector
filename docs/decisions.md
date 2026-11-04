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

### 2026-11-03: Phase 0 design
Agreed section by section and written in `superpowers/specs/2026-11-03-phase-0-foundation-design.md`. The decisions in it:

- **Limits, in USD:** OpenRouter inference key $34 a month; LiteLLM global $32; team `permanent` $8 (key `node-red` $4); team `experiments` $24 (key `smoke-test` $1). All reset on the 1st at 00:00 UTC.
- **Starting set:** four roles (`classify`, `summarise`, `code`, `chat`) and seven experiment names, each pinned to one zero data retention endpoint. No free models.
- **Ports:** gateway 4000, `chat` 4010, tower 4020.
- **Open WebUI:** titles on with `llama-3.1-8b-instruct@deepinfra`; other background calls, web search and image generation off; settings fixed by environment variables.
- **The OpenRouter key variable is `RAPIDSELECTOR_OPENROUTER_KEY`,** so LiteLLM's `/openrouter` pass-through, which records $0 spend, finds no key.
- **Virtual keys are generated in advance** and stored as secrets; `setup-keys.sh` registers them.
- **`/metrics` without authentication.**
- **Alert rules** are created through the Grafana MCP from a local Claude Code session.
- **Web search** parked (`roadmap.md`).

### 2026-11-04: Phase 0 built and tested at level 1
Implemented following `superpowers/plans/2026-11-03-phase-0-foundation.md`; 79 level 1 tests pass (`tests/run.sh`). Not yet verified on the Pi: levels 2 and 3 follow `test-procedures/phase-0.md`, walked through with Claude. The `production` repository's changes are on its branch `claude/ecstatic-hypatia-t1sj0o`, for the owner to merge. Decided by the owner after the final review:
- **`gateway/request_guard.py` is accepted:** a small LiteLLM pre-call callback of our own that removes `extra_body`, `provider`, `models`, `route`, `transforms` and `fallbacks` from every request. Reason: a request body could otherwise replace the pin, including zero data retention, or add OpenRouter's fallback model list.
- **`gpt-oss-120b@primeintellect` is replaced by `gpt-oss-120b@coreweave`** (`coreweave/fp4`, $0.03 / $0.17). Reason: PrimeIntellect's price changed four times in a day. The same-model comparison stays: DeepInfra bf16 against CoreWeave fp4.
- **`node-red` gets a limit of 100,000 tokens a minute**, besides 30 calls a minute and $4 a month. Reason: `CLAUDE.md` requires an input-size limit for automated clients.

### 2026-11-04: Drain test and procedure changed before any money was spent
Option 3 of 3 in `superpowers/specs/2026-11-04-drain-test-fixes-design.md`, chosen by the owner. `scripts/drain-balance.sh` now sends rounds of parallel calls (default 5) instead of a burst after the first refusal, does not start a round that could pass `--max-usd`, and tells limit refusals from faults, the gateway's budget and temporary in-flight refusals. It halves `max_tokens` on a limit refusal, down to 16. Reasons: a passing 429 or 503 would have been reported as a working limit; D6 could have stopped with money left; only simultaneous calls can show a call crossing a limit. Added to the procedure: a level 1 run on `sandbox` before B2 (B1a), a reboot check (C5) and a budget alert test (D8). Corrected: D6 does not fire the alerts by itself. Results about simultaneous calls hold for a small balance on a new account (`provider-facts.md`).

## Open

### Settle during design or phase 0

1. **Is the loss really capped?** Test with a very small balance, since this costs a little real money. The docs mention negative balances without saying how far one can go (`provider-facts.md`). The test needs a cost ceiling agreed in advance.
2. **How do key limits behave in practice?** The docs now confirm a monthly reset option and a 402 error when the key's limit is reached (`provider-facts.md`). Still to test: that the limit actually stops calls, and how a request that crosses the limit is charged.
3. **How does LiteLLM record OpenRouter spend?** Either explicit prices in the gateway config, or the actual cost from OpenRouter's response if LiteLLM reads it. Also confirm that LiteLLM passes on the host pin and zero data retention settings. **Answered in part at level 1, 2026-11-04** (`provider-facts.md`): LiteLLM v1.106.6 records OpenRouter's `usage.cost` when the response has one, and the configured price otherwise; it forwards the `provider` object unchanged, and `gateway/request_guard.py` stops a request body from replacing it (`extra_body`) or adding OpenRouter routing (`models`, `route`, `transforms`). Still to see at level 3: that OpenRouter's real responses carry the cost, and that the pins are honoured.
4. **Is the Standard plan free of any subscription fee?** The owner wants pay as you go with no flat rates, and only the 5.5% credit fee has been seen so far.
5. **Do the wanted models have zero data retention hosts?** For example, `lfm-2.5-2.6b` had none listed. Every entry in the phase 0 starting set is on OpenRouter's list of zero data retention endpoints (2026-11-03); level 3 confirms they are honoured.
6. **Management key expiry.** OpenRouter recommends an expiry date on every management key, and it cannot be changed after creation. Decide whether to use one, and how `tower` gets a new key before the old one expires.
7. **Does the stack fit on the Pi?** Check that LiteLLM's images (including the Postgres variant) exist for arm64, and how much RAM LiteLLM and Open WebUI need. Open WebUI's local embedding and RAG features may need to be turned off.
8. ~~Is LiteLLM's spend log retention free or an Enterprise feature?~~ **Settled 2026-11-03:** free ("Retention and cleanup are open source"); set to `90d` in phase 0.
9. ~~Which Open WebUI features call outside services, and how are they turned off?~~ **Settled 2026-11-03:** web search, image generation, the Ollama connection and direct connections are turned off with environment variables, and `ENABLE_PERSISTENT_CONFIG=False` keeps them off (phase 0 spec, section 4).
10. **`tower` stack.** The owner chooses, after options and a recommendation are presented. Phase 1, first, together with the level of visual ambition (A clean and functional, B distinctive, C experimental; see the overall design, section 11).
11. ~~Are LiteLLM teams available in the open-source version?~~ **Settled 2026-11-04 (level 1):** yes. Teams, team budgets and custom key values work in v1.106.6 without a licence.
12. ~~Which error does LiteLLM return for an exhausted budget?~~ **Settled 2026-11-04 (level 1):** HTTP 422 with `"type": "budget_exceeded"` (the docs' example says 400). Key and team budgets stop within one call; the global budget overshot by a few calls, and the team budgets, which add up to it, are what stop spend promptly. The README tells clients not to retry it.
13. ~~Does LiteLLM's `/metrics` require auth by default?~~ **Settled 2026-11-03:** yes, from v1.85.0. Turned off (`require_auth_for_metrics_endpoint: false`), like `node_exporter` on the owner's hosts.
14. ~~What does LiteLLM do if the database disappears while running?~~ **Settled 2026-11-04 (level 1):** it fails closed. A spent key stays refused (422), other keys get 503 "the authentication database is temporarily unreachable", and calls work again once Postgres returns.
15. ~~How do container logs reach Loki?~~ **Settled 2026-11-03:** they don't in phase 0. None of the owner's containers ship logs to Loki today; a fleet-wide Promtail change later would cover rapid-selector too. Logs are rotated locally.
16. ~~How is the empty-balance case tested?~~ **Settled 2026-11-03:** both ways, at the first top-up: test B (key limit) first, then the spend and host checks, then test A (use up the smallest top-up). Ceiling $1 plus the top-up. Claude walks the owner through it.
17. **Can tower use an admin key other than LiteLLM's master key?** Phase 1.
18. **Which OpenRouter endpoint gives the inference key's limit and usage to the management key?** Phase 1.
19. **Node-RED name resolution** (`production` repository, any time). Node-RED uses `--add-host` for every name. Hypothesis: Docker falls back to public DNS because the host's resolver is a local address, and pointing the container at the router (`--dns`) would fix it. Check `/etc/resolv.conf` on `messagebroker` and inside the container. Until fixed, Node-RED needs `--add-host` for `llm`.

### Deferred findings from the phase 0 review (2026-11-04)
Minor, not fixed yet; each to be decided by the owner.
20. Secrets are visible in `ps` on the host while the scripts run (curl headers and `-d` payloads). Could pass them on stdin (`curl -K -`, `--data @-`).
21. `POSTGRES_PASSWORD` goes into `DATABASE_URL`, so characters such as `@ / : # % ?` break the gateway. `.env.example` should say hex only.
22. Special characters in secrets are not tested through real `docker compose` and the secrets-service blob.
23. secrets-service errors give only the HTTP status, not its meaning (401 token rejected, 423 secret deactivated, 404 unknown name).
24. The restart test accepts any non-200; it should assert 422 `budget_exceeded`.
25. The database-down test lacks a cached key with budget left.
26. ~~Test B (D1) on `qwen3.8-2.4t-a95b` with `max_tokens` 8192 may be refused outright by OpenRouter's in-flight hold, so the overshoot at the key limit would not show.~~ **Settled 2026-11-04:** `--max-tokens`, and halving on a refusal.
27. ~~`drain-balance.sh`'s burst of 5 is outside `--max-usd`, and any non-200 counts as "refused".~~ **Settled 2026-11-04:** the burst is gone, rounds are checked against `--max-usd`, and refusals are sorted.
28. ~~The status the gateway returns for a 402 from OpenRouter is not asserted.~~ **Settled 2026-11-04 (level 1):** 402 and 403 are passed on, asserted through `tests/drain.bats`. Level 3 shows OpenRouter's real answers.
29. ~~The procedure lacks a live `tests/check-prices.sh` run before D3 and D4, and a reboot check (ports bound to the LAN address at boot).~~ **Settled 2026-11-04:** added before D3 and D6, and as step C5. Live check today: all 11 entries match.
30. README gaps: `chmod 600` on `.env` and the token file; `setup-keys.sh` must be rerun after adding a model; rotating a `KEY_*` leaves the old key active; admin-UI edits to fields `setup-keys.sh` does not send stay.
31. The "database failing" alert may see a rise if Prometheus's first scrape lands while LiteLLM counts its start-up query failures; checked by the reboot at step C5.
32. `tests/run.sh` has no guard against a host running the real stack. The test stack has its own project name (`rapidselector-test`, in `tests/compose.test.yml` and `tests/compose.fakes.yml`), so by reading the files its `down -v` should leave the real volumes alone, but both stacks use the same fixed container names, so starting it there fails. The README and step B1a say not to do it; a guard could refuse with a clear message. Not tried on a host with the real stack.
33. Two timing checks in `tests/drain.bats` ("--parallel sends the calls of a round at once" and "the default is 5 calls at once") expect calls to arrive within 1.5 seconds of each other, which may fail spuriously on slower arm64 hardware. A longer `delay_ms` and a wider margin would keep the check.
34. `drain-balance.sh --parallel` with no value exits 1 with no message, from `shift 2` under `set -e`. The other value flags are parsed the same way. Harmless, since no key exists yet.
35. `api` in `scripts/lib.sh` has no `--max-time`, so a hung gateway can block `drain-balance.sh`'s summary and the deletion of the temporary key `drain-test`.
36. Gaps in `tests/drain.bats`: no test has a fault and a limit refusal in the same round, or a limit and an in-flight refusal in the same round, and SIGINT is not tested, only TERM (the final review tried INT by hand, and it works).

### Settle later

- **Is an asynchronous layer such as MQTT needed at all?** Decided per use case, from its own needs (phase 3 and later).
