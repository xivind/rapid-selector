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
- **Clients reach the gateway as `llm`,** a name alias on the router pointing to the current host. *Replaced by "Clients call the host by name", 2026-11-05.*
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

- **Limits, in USD:** OpenRouter inference key $34 a month (raised to $35 on 2026-11-05, question 37); LiteLLM global $32; team `permanent` $8 (key `node-red` $4); team `experiments` $24 (key `smoke-test` $1). All reset on the 1st at 00:00 UTC.
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

### 2026-11-04: Memory limits are not enforced on the owner's Pis
*Replaced by "Memory limits removed", 2026-11-05.*

The kernel's memory control stays off on `sandbox`, and the limits stay in `docker-compose.yml`, where they work on any host that has it. Decided by the owner. Reason: they protect the host, not the budget; none of the owner's other containers have limits; and turning it on changes the whole host, `webserver` included. The cost: a memory leak in a service could fill the host, and `node_exporter` shows the host, not which container. To revisit if step B5 looks high or a host memory alert fires: the README has the one-line boot setting. `CLAUDE.md` changed with the owner's permission.

### 2026-11-04: Level 1 passes on `sandbox` (step B1a)
The first full run on the Pi 5, arm64, on branch `drain-test-fixes`: 101 of 103 tests passed in about 25 minutes. The two failures (`chat starts without downloading models`, `every container has a memory limit and log rotation`) came from the kernel's memory control being off. After the decision above changed those tests, `tests/chat.bats` and `tests/resilience.bats` passed in full (12 of 12), so every test has now passed on the Pi, though not in one run. `jq` had to be installed on `sandbox`, and `bats` was fetched directly, since `sandbox` has no Node. The fake upstream was used: nothing was spent. This also shows the images run on arm64 (open question 7). Whether the stack fits in memory is still to see at step B5.

### 2026-11-04: Step A1, OpenRouter's account settings
Done by the owner in OpenRouter's dashboard. Auto top-up: off by default, and it needs a saved payment method, which the owner has not added; to be rechecked after buying credits at A3. Under Data Policies, Zero Data Retention: "All other models", "Anthropic", "OpenAI", "Google" and "SpaceXAI" on, with `ZDR only` under "All other models" and "Google". Data Training: "Allow paid endpoints that train on request data", "Allow free endpoints that train on request data", "Allow free endpoints that publish prompts" and "Allow 1% data discount in workspaces" all off. Allowed Providers: Cloudflare, CoreWeave, DeepInfra and SiliconFlow, chosen by the owner as a limit enforced at OpenRouter; a new host needs a change there too. Eligibility Preview shows 121 available, and whether the 9 models are among them was not checked by name: B6 and D3 will show it. Reason for `ZDR only`: the default, `Allow Safety Retention`, lets a host keep prompts for abuse prevention, also with `provider.zdr: true` (`provider-facts.md`).

### 2026-11-04: Step A2, the gateway's inference key
Created by the owner as a workspace API key: `rapidselector-gateway`, credit limit $0.05, monthly reset. The limit rises to $34 at step D2.

### 2026-11-04: Step A3, the first top-up
The owner bought $5 of credit and paid $7.25 with Google Pay through Stripe, so OpenRouter holds no card. The balance shows $5.00, auto top-up is still off, and there is no sign of a subscription or recurring fee. The cost ceiling for the procedure is therefore $6 of credit, not counting the regular top-up at D7. The $2.25 on top was higher than the 5.5% fee alone: see open question 37 below.

### 2026-11-05: Step B1, settings and secrets on `sandbox`
Done by the owner. `sandbox` is on `main`, and `hostname -I` gives `192.168.1.212`, which is set in `.env` with `SECRETS_SOURCE=secrets-service` and the token file. `.env` and the token file are `-rw-------`, and the token file's folder is `drwx------`. The client `rapidselector` was created in secrets-service; its token was accepted (404 before the secret existed). The secret `rapidselector` was stored with all 9 fields and read back from the service, by name and length only: `POSTGRES_PASSWORD` 64, `LITELLM_MASTER_KEY` 51, `LITELLM_SALT_KEY` 64, `LITELLM_UI_PASSWORD` 32, `RAPIDSELECTOR_OPENROUTER_KEY` 73, `WEBUI_SECRET_KEY` 64, `KEY_CHAT` 51, `KEY_NODE_RED` 51, `KEY_SMOKE_TEST` 51. The temporary file was deleted. Nothing was started, and it cost nothing. The one-line `jq` command in the handoff did not survive pasting (`subsh>`, nothing ran), so it was replaced by a tested version with short lines. No value was seen by Claude. The owner sees the row `rapidselector` in the admin UI, and confirms that secrets-service's `encryption.key` and admin password are noted in a safe place, which is what makes the `MASTERDB` backup of these secrets readable; Claude cannot verify this, and no restore of it has been tried here.

### 2026-11-05: Step B2, first start on `sandbox`
`./rapidselector.sh up -d` created the network, both volumes and the three containers, with no leftovers from B1a. After about 3 minutes `rapidselector-db`, `rapidselector-gateway` and `rapidselector-chat` were all `healthy`. Ports are published on `192.168.1.212` only (gateway 4000, chat 4010), and Postgres shows `5432/tcp` with no host address, so it is not published. Docker warned `Limitation discarded` for all three, as expected from the memory decision above. `free -h` before the start: 1.0 GiB used, 6.8 GiB available, of 7.9 GiB, swap unused. About a minute after the start, with chat not yet healthy: 2.3 GiB used, 5.5 GiB available. B5 compares properly. It cost nothing.

### 2026-11-05: Step B3, teams and keys registered
`setup-keys.sh` printed the expected table: team `permanent` $8 and 4 names; team `experiments` $24 and 11 names; `node-red` in `permanent`, $4, 4 names, 30 calls a minute; `chat` in `experiments`, using the team's budget, 11 names; `smoke-test` in `experiments`, $1, 11 names. Budgets show the `30d` window. Whether they reset on the 1st, as LiteLLM's docs say, cannot be seen until a month has turned. It cost nothing.

### 2026-11-05: Step B4, the chat admin account
The owner created the admin account in Open WebUI and sees all 11 names in the model list: 4 roles and 7 experiments. No chat message was sent, and it cost nothing.

### 2026-11-05: Memory limits removed
Decided by the owner, after seeing `Limitation discarded` for all three containers at B2. `mem_limit` is gone from `docker-compose.yml`, and `CLAUDE.md` changed by the same decision. Reason: the limits do nothing on the owner's hosts, and the warning appears at every start. The cost: on a host with memory control on, nothing now stops a leak in one container from filling the host; others using the repository must add limits themselves, and the README says so. To bring them back: the values were 512m for `db` and 1536m each for `gateway` and `chat`, and a Pi also needs `cgroup_enable=memory cgroup_memory=1` in `/boot/firmware/cmdline.txt` and a reboot, which affects the whole host.

### 2026-11-05: `up` is always detached
Decided by the owner: containers should always run in the background. `docker compose up` stays attached without `-d`, and neither a Compose file setting nor a `COMPOSE_*` variable changes that (`provider-facts.md`), so `./rapidselector.sh up` adds `-d` itself. `up -d` still works. Other commands, and calls with options before `up`, are passed on unchanged.

Checked by the owner on `sandbox`, on branch `phase-0-walkthrough`: `./rapidselector.sh up` without `-d` recreated the three containers and returned to the prompt, with no `Limitation discarded` lines, and all three were `healthy` about a minute later, with ports as at B2.

### 2026-11-05: Step B5, the stack fits in memory
Measured on `sandbox` a few minutes after the containers were recreated, idle, with no model called yet. `free -h`: 2.3 GiB used, 5.6 GiB available, of 7.9 GiB, swap unused. Before the first start (B2) it was 1.0 GiB used and 6.8 GiB available, so the stack takes about 1.2–1.3 GiB. The biggest processes: `python3` at about 857 MiB, presumably Open WebUI, and `litellm` at about 593 MiB; the largest `postgres` process listed is about 27 MiB. Nothing needs changing. Use under load has not been measured; the models run elsewhere, so the Pi only handles the traffic. The chat page also opened as the existing admin account after the recreation, without asking to create one, so the account survived. It cost nothing.

### 2026-11-05: Step B6, the smoke test, and the first real spend
On `sandbox`, `smoke-test.sh` got status 200 and a cost above zero for all four roles: `chat` $0.00000494, `classify` $0.00000108, `code` $0.00000126, `summarise` $0.00000250, in total $0.00000978. `openai/gpt-4o` and `/openrouter/v1/chat/completions` were both refused with 403, and it ended with `OK`. OpenRouter's activity page shows 4 requests, one each for the four pinned models, at $0.000004, $0.000001, $0.000002 and $0.000001: the gateway's figures cut off at six decimals, so the two agree. The balance and the key's usage were not read this time. The same page also has a table of the four models with figures from $0.0526 to $0.0952, which is not spend (the calls could not have cost that, and the key's $0.05 limit did not trigger); what it measures was not settled. The live `tests/check-prices.sh` passed for all 11 entries the same day.

### 2026-11-05: Step C1, Prometheus watches the gateway
On `home-assistant`, the owner pulled the `production` repository and restarted Prometheus. The target `http://sandbox:4000/metrics/` for job `rapidselector-gateway` is `up`, with no error. It cost nothing.

### 2026-11-05: Step C2, the alert rules
Created through the Grafana MCP from a separate session in the `production` repository: all 8 rules in folder Alerts, evaluated every 60 seconds, read back as matching the notes, and none firing. Grafana went from 19 to 27 rules. The owner named the group `LLM` instead of `rapid-selector`; the rules keep their `rapid-selector:` names. Three rules are `Normal`, and five are `Normal (NoData)`, as nothing has happened yet for them to measure. The backup count stays at 9 until E1.

### 2026-11-05: Step C3, the backup key
On `sandbox`, the user `rapidselector-backup` and `/usr/local/bin/rapidselector-export.sh` were installed, with `home-assistant`'s new key restricted to that script. From `home-assistant`, `postgres` returned a dump ending in `-- PostgreSQL database dump complete`, and `chat` returned paths under `app/backend/data/`, with `rapidselector-chat` stopped and started again; all three services were `healthy` afterwards. The user is in the `docker` group, so its forced command is what limits it. The chat backup holds `cache/embedding/models/`, though embeddings are off and no download was seen; to look at with the file sizes at E1. The owner keeps `grafana/rapidselector-alerts.md` in `production`. It cost nothing.

### 2026-11-05: Step C4, Node-RED can reach the gateway
On `messagebroker`, with a fresh Node-RED backup first (`ok`), the owner ran `nodered/create-container-nodered.sh` as it is. That script deletes the image and takes the newest, but Node-RED stayed at v5.0.9. The container's hosts and volume matched the script beforehand. Afterwards it was `healthy`, flows started with no errors or missing nodes, `/etc/hosts` has `192.168.1.212 llm`, it reached `http://llm:4000/metrics/`, and the owner checked the flows in the editor. The router alias was dropped: see "Clients call the host by name" below. From inside Node-RED, `http://sandbox:4000/metrics/` also answers, and the `llm` line is gone from the script; the running container keeps the entry until it is next recreated, which does no harm. It cost nothing.

### 2026-11-05: Clients call the host by name
Clients reach the gateway at the host's own name, today `http://sandbox:4000`, not through an alias `llm`. Decided by the owner, who has a Google Nest router and doubted it can hold an alias. Reason: it matches how everything else in the home is called, and moving to `webserver` is a one-time change. The cost: every flow and app that calls the gateway must be edited at the move. Node-RED already has `sandbox` in its `--add-host` list.

### 2026-11-05: Step C5, the reboot check, waits for the move to `webserver`
Decided by the owner. The check still has to pass, so phase 0 is not verified until it has, and finding 31 stays open. It does not protect the budget, so section D goes ahead without it. The cost: until it is run, it is not known that the stack comes back by itself after a reboot on the LAN address. If `sandbox` restarts unexpectedly, check `./rapidselector.sh ps` and `ss -tln`.

### 2026-11-05: Step D1, the key limit stops calls, but late
`drain-balance.sh --max-usd 0.10 --max-tokens 1024 --parallel 5` on `qwen3.8-2.4t-a95b@siliconflow`: three rounds of 5 calls, all 200, $0.031080 each, $0.093240 in total, recorded by the gateway as $0.09324, and `stopped: max-usd`. The script's own ceiling stopped it before a fourth round, not OpenRouter: no call was refused, though round 3 started at $0.062 spent. OpenRouter's activity page shows $0.0932 for that model, matching the gateway. The temporary key `drain-test` was deleted by the script.

Then, with the owner's approval, two checks that cost nothing. `GET /api/v1/key` with the gateway's key showed it is the key with the limit: `limit` 0.05, `limit_reset` monthly, one budget, `scope` `key_limit`, `spend_usd` 0.093249775, `remaining_usd` −0.0432, no guardrail or workspace budget. The workspace has only that key. One call to `classify` afterwards was refused: HTTP 403, `limit_source` `openrouter_key_limit`, `scope` `key_limit`, "Key limit exceeded (monthly limit) … $0.09 of $0.05 used", passed on by the gateway as 403 `permission_error`.

So the limit is enforced, but against spend OpenRouter has already counted, and calls started before that pass and are charged in full: here 86% past the limit, $0.043. How long the delay is was not measured. Spend stayed within the step's stated cost.

**Decided by the owner, the same day: accept it** (option A of 2; B was to measure the delay, for about $0.05–0.10 more). The key limit is a backstop that can be passed by whatever is running, or starts, before OpenRouter has counted the spend; the owner expects the delay to be seconds, a minute at most, which is not measured. The gateway's budgets stay below the key limit, so the gateway stops first in normal use, and the balance stays the hard cap and is kept small.

### 2026-11-05: The key's monthly limit is $35
Decided by the owner, who wanted a round number and can change it later in OpenRouter's dashboard. Settles question 37. At about 9.28 NOK per USD (mid-market, early November 2026), 400 NOK is about $43 including everything. Credit plus the 5.5% fee plus 25% VAT, as $5 cost $7.25 at A3: $35 a month costs about $46.16, about 428 NOK, if fully used; $32 would have been about 392 NOK. The receipt's breakdown was not read. The gateway's budgets stay as they are ($32 global), so in normal use the gateway stops at $32, about 392 NOK, and the key limit is the backstop $3 above it. Raising or lowering the key limit needs only the dashboard; changing the gateway's budgets needs `gateway/config.yaml` and `scripts/setup-keys.sh`, kept below the key limit.

### 2026-11-05: Step D2, the key limit raised to $35
Set by the owner on OpenRouter's Keys page. `GET /api/v1/key` with the gateway's key: `limit` 35, `limit_reset` monthly, `limit_remaining` 34.906750225, `usage_monthly` 0.093249775. It cost nothing.

### 2026-11-05: Step D3, spend per model (one model still to answer)
`tests/check-prices.sh`: `ok` for all 11 entries. `smoke-test.sh --all`: 10 names with 200 and a cost above zero, `qwen3.8-2.4t-a95b@siliconflow` the largest at $0.00023; both probes refused with 403; $0.00026194 in total. `gpt-oss-20b@deepinfra` got 429. The gateway's log shows it came from DeepInfra through OpenRouter: "temporarily rate-limited upstream", `provider_error_code` `engine_overloaded`, `limit_source` `upstream_provider_shared_pool`, passed on with no fallback, as the pin requires, after LiteLLM retried twice. Called twice more over about half an hour: 429 both times, cost 0. To be called again another day; it does not hold up the rest of D.

### 2026-11-05: Step D4, every call served by its pin, at the gateway's cost
OpenRouter's per-model summary for the period agrees with the gateway once each call is cut off at six decimals: gpt-oss-120b $0.000017 (four calls: 4 + 4 + 4 + 5 millionths), DeepSeek V4.1 Flash $0.00001, Qwen3 Coder $0.000002, Gemma 4 $0.000004, Mistral Small 3.2 $0.000002 (two calls each, B6 and D3), Qwen3.8 $0.0935 (D1 plus D3), and Llama 3.2 1B and Llama 3.1 8B $0, as both cost under a millionth ($0.00000086 and $0.00000044). That summary shows no host or quantisation.

OpenRouter's Logs page lists each call with its tokens and cost, and the paste had no host column. All 10 D3 costs are exact there, for example $0.000000861 for Llama 3.2 1B and $0.00000542 for gpt-oss-120b at CoreWeave. Checked against the public price list (`/api/v1/endpoints/zdr`), only the pinned host's price fits each call's tokens among the four allowed providers, for 9 of the 10: Gemma 4 costs the same at CoreWeave and Cloudflare ($0.10 / $0.30), and the owner read CoreWeave in that call's provider responses. So all 10 were served by their pin. The same page shows D1's 15 calls at 1,024 output tokens and $0.00622 each, from 18:56 to 18:57, so each round took about 25–30 seconds and the next started at once; round 3 passing only shows that round 2's spend was not yet counted at that moment.

### 2026-11-05: Step D5's temporary entry
Claude checked every non-free endpoint OpenRouter lists against `/api/v1/endpoints/zdr`: at the four allowed providers, the only endpoints without zero data retention are `:batch` variants at DeepInfra. So D5 uses `openai/gpt-oss-20b:batch` pinned to `deepinfra/bf16` ($0.024 / $0.112 per million tokens), which the account's allowed-provider list does not block, so a refusal comes from the data policy alone: the pin's `zdr: true` or the account's `ZDR only`. `max_tokens` is 16, so a call that got through would cost under $0.00001. `:batch` is a separate product, and it may be refused for its own reasons; the message will tell.

First try, the same day: refused with HTTP 404, "openai/gpt-oss-20b:batch cannot be used with the chat/completions endpoint (adapter DeepInfraBatchAdapter)", so the data policy was not tested. Second choice: `openai/gpt-oss-20b` at `darkbloom/fp8` ($0.018 / $0.09 per million tokens), not on the zero data retention list and not an allowed provider. A refusal then shows that the account blocks it, through the provider list, the data policy or both, which is what the procedure accepts; the data policy alone cannot be tested at the four allowed providers, as none has an ordinary endpoint without zero data retention. Also found: the gateway reads `gateway/config.yaml` through a mounted file, so `up` does not reload it, and the procedure and README now say `restart gateway`.

### 2026-11-05: Step D5, an endpoint outside the account's settings is refused
With the temporary entry `zdr-negative-test` (`openai/gpt-oss-20b` pinned to `darkbloom/fp8`, which has no zero data retention) and the master key: HTTP 404 from OpenRouter, "No allowed providers are available for the selected model … your account's allowed-providers setting permits only: coreweave, deepinfra, cloudflare, siliconflow", `failed_routing_step` "Filter by Allowed Providers". The gateway passed it on as 404 and tried no fallback. Nothing was charged. So the account's allowed-provider list stopped it, before the data policy was reached; the data policy on its own stays untested, since no allowed provider has an ordinary endpoint without zero data retention (see "Step D5's temporary entry"). The script that added the entry is deleted.

### 2026-11-05: Tower shows every setting, and changes none
Decided by the owner while designing tower part 1 (option B of 3; A was git only with nothing shown, C was changing roles and models from tower). Tower shows every setting, neatly organised: each role and experiment name with its model, host pin, price, default `max_tokens` and zero data retention; teams and keys with budgets, spend, resets, allowed names and rate limits; the OpenRouter key's limit, usage and reset; whether the latest price check passed; Open WebUI's settings; and OpenRouter's account settings. Secret values are shown only as set or not set. Changes still go through `gateway/config.yaml` and `scripts/setup-keys.sh` in git, the price check and the smoke test. Reason: one place to see the whole setup, without a second way to change it. How tower reads Open WebUI's settings is for the design. **OpenRouter's account settings are left out** (decided the same day): OpenRouter has no API for them, and a record kept by hand would not stay up to date.

### 2026-11-05: Tower's look is "distinctive" (level B)
Chosen by the owner from three mockups of the first screen: A clean and functional (the production stack's Bootstrap look), B distinctive, C experimental (interactive D3 or canvas maps). B: a visual identity of its own, shown as dark, warm and typographic, a nod to Bush's microfilm machine, with custom but simple charts. Settles the first half of question 10; the stack is next.

### 2026-11-05: Tower in USD, for today, this week and this month
Decided by the owner. Tower shows amounts in USD only, not NOK, to keep it simple; `requirements.md` changed. It covers today, this week and this month, and Grafana the same periods plus longer ones. The owner also agreed to three proposals: tower does not repeat Grafana's history; a "Log" section lists kill switch changes and balance snapshots; usage per role and model comes from the gateway's spend log, if the open-source version offers the reports (to check).

### 2026-11-05: Tower's stack
Chosen by the owner (option 1 of 3): FastAPI and Jinja2, rendered on the server, with our own stylesheet instead of Bootstrap, charts drawn as SVG on the server, `htmx` for parts of a page that update or act, and SQLite through Peewee for tower's own data, tested with `pytest`. A richer chart in phase 2 can use D3 on its own page. The others: 2, FastAPI serving data to plain JavaScript with D3 or Observable Plot in the browser; 3, Svelte or React in front of FastAPI, with Node tooling and a build step. Reason: the owner's production stack, one language and one test setup, the fewest moving parts, and enough for look B. The owner asked that none be a dying technology: in early November 2026, FastAPI had 0.139.1 (July 2026), Peewee 4.0.8 (June 2026), htmx is on version 2 with version 4 under way; Jinja2 was not checked. Settles question 10.

### 2026-11-05: The management key expires after a year
Decided by the owner (option B of 3; A no expiry, C 90 days). Tower shows the days left, a Grafana alert warns 30 days before, and the README gets the steps to create a new key and update the secret. When it expires, tower cannot read the balance or use kill switch level 2; the README's manual ways still work. Settles question 6.

## Open

### Settle during design or phase 0

1. **Is the loss really capped?** Test with a very small balance, since this costs a little real money. The docs mention negative balances without saying how far one can go (`provider-facts.md`). The test needs a cost ceiling agreed in advance.
2. ~~How do key limits behave in practice?~~ **Answered 2026-11-05 (D1):** the limit stops calls, with 403 `openrouter_key_limit`, but only after the spend is counted. Calls that started before are charged in full, so the key went to $0.093 on a $0.05 limit. The monthly reset is not seen until December 1.
3. **How does LiteLLM record OpenRouter spend?** Either explicit prices in the gateway config, or the actual cost from OpenRouter's response if LiteLLM reads it. Also confirm that LiteLLM passes on the host pin and zero data retention settings. **Answered in part at level 1, 2026-11-04** (`provider-facts.md`): LiteLLM v1.106.6 records OpenRouter's `usage.cost` when the response has one, and the configured price otherwise; it forwards the `provider` object unchanged, and `gateway/request_guard.py` stops a request body from replacing it (`extra_body`) or adding OpenRouter routing (`models`, `route`, `transforms`). Still to see at level 3: that OpenRouter's real responses carry the cost, and that the pins are honoured.
4. ~~Is the Standard plan free of any subscription fee?~~ **Settled 2026-11-04:** no sign of a subscription or recurring fee after the first top-up, and OpenRouter's pricing page says "no minimums and no lock-in".
5. **Do the wanted models have zero data retention hosts?** For example, `lfm-2.5-2.6b` had none listed. Every entry in the phase 0 starting set is on OpenRouter's list of zero data retention endpoints (2026-11-03); level 3 confirms they are honoured.
6. ~~Management key expiry.~~ **Settled 2026-11-05:** a year, with a warning (see "The management key expires after a year").
7. ~~Does the stack fit on the Pi?~~ **Settled 2026-11-05, while idle:** the images run on arm64 (B1a), and the stack takes about 1.3 GiB of the 8 GB (B5). Open WebUI's local embedding is off.
8. ~~Is LiteLLM's spend log retention free or an Enterprise feature?~~ **Settled 2026-11-03:** free ("Retention and cleanup are open source"); set to `90d` in phase 0.
9. ~~Which Open WebUI features call outside services, and how are they turned off?~~ **Settled 2026-11-03:** web search, image generation, the Ollama connection and direct connections are turned off with environment variables, and `ENABLE_PERSISTENT_CONFIG=False` keeps them off (phase 0 spec, section 4).
10. ~~`tower` stack.~~ **Settled 2026-11-05:** look B and stack 1 (see "Tower's stack").
11. ~~Are LiteLLM teams available in the open-source version?~~ **Settled 2026-11-04 (level 1):** yes. Teams, team budgets and custom key values work in v1.106.6 without a licence.
12. ~~Which error does LiteLLM return for an exhausted budget?~~ **Settled 2026-11-04 (level 1):** HTTP 422 with `"type": "budget_exceeded"` (the docs' example says 400). Key and team budgets stop within one call; the global budget overshot by a few calls, and the team budgets, which add up to it, are what stop spend promptly. The README tells clients not to retry it.
13. ~~Does LiteLLM's `/metrics` require auth by default?~~ **Settled 2026-11-03:** yes, from v1.85.0. Turned off (`require_auth_for_metrics_endpoint: false`), like `node_exporter` on the owner's hosts.
14. ~~What does LiteLLM do if the database disappears while running?~~ **Settled 2026-11-04 (level 1):** it fails closed. A spent key stays refused (422), other keys get 503 "the authentication database is temporarily unreachable", and calls work again once Postgres returns.
15. ~~How do container logs reach Loki?~~ **Settled 2026-11-03:** they don't in phase 0. None of the owner's containers ship logs to Loki today; a fleet-wide Promtail change later would cover rapid-selector too. Logs are rotated locally.
16. ~~How is the empty-balance case tested?~~ **Settled 2026-11-03:** both ways, at the first top-up: test B (key limit) first, then the spend and host checks, then test A (use up the smallest top-up). Ceiling $1 plus the top-up. Claude walks the owner through it.
17. **Can tower use an admin key other than LiteLLM's master key?** Phase 1.
18. **Which OpenRouter endpoint gives the inference key's limit and usage to the management key?** Phase 1.
19. **Node-RED name resolution** (`production` repository, any time). Node-RED uses `--add-host` for every name. Hypothesis: Docker falls back to public DNS because the host's resolver is a local address, and pointing the container at the router (`--dns`) would fix it. Check `/etc/resolv.conf` on `messagebroker` and inside the container. Until fixed, Node-RED needs `--add-host` for every host it calls.

37. ~~Is the $34 limit too high for the 400 NOK budget, now that VAT is known?~~ **Settled 2026-11-05:** see "The key's monthly limit is $35".

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
30. README gaps: `setup-keys.sh` must be rerun after adding a model; rotating a `KEY_*` leaves the old key active; admin-UI edits to fields `setup-keys.sh` does not send stay.
31. The "database failing" alert may see a rise if Prometheus's first scrape lands while LiteLLM counts its start-up query failures; checked by the reboot at step C5.
32. `tests/run.sh` has no guard against a host running the real stack. The test stack has its own project name (`rapidselector-test`, in `tests/compose.test.yml` and `tests/compose.fakes.yml`), so by reading the files its `down -v` should leave the real volumes alone, but both stacks use the same fixed container names, so starting it there fails. The README and step B1a say not to do it; a guard could refuse with a clear message. Not tried on a host with the real stack.
33. Two timing checks in `tests/drain.bats` ("--parallel sends the calls of a round at once" and "the default is 5 calls at once") expect calls to arrive within 1.5 seconds of each other, which may fail spuriously on slower arm64 hardware. A longer `delay_ms` and a wider margin would keep the check.
34. `drain-balance.sh --parallel` with no value exits 1 with no message, from `shift 2` under `set -e`. The other value flags are parsed the same way. Harmless, since no key exists yet.
35. `api` in `scripts/lib.sh` has no `--max-time`, so a hung gateway can block `drain-balance.sh`'s summary and the deletion of the temporary key `drain-test`.
36. Gaps in `tests/drain.bats`: no test has a fault and a limit refusal in the same round, or a limit and an in-flight refusal in the same round, and SIGINT is not tested, only TERM (the final review tried INT by hand, and it works).
38. *(2026-11-05, seen at D3)* The gateway's log has "You are sending unauthenticated requests to the HF Hub", so LiteLLM fetches something from Hugging Face, probably a tokenizer for counting tokens. No prompt is involved as far as is known, but it is an outside call nobody chose. Find out what it fetches and whether it can be turned off or pinned.
39. *(2026-11-05, seen at D3)* LiteLLM retries 403, 429 and 503 twice by itself, as level 1 already showed (`provider-facts.md`), and the gateway's log confirmed it for a real 429. One client call can be three calls upstream, and with the README's one client retry, six. A refused call costs nothing; a retried call that timed out might. Decide whether to set `num_retries`.

### Settle later

- **Is an asynchronous layer such as MQTT needed at all?** Decided per use case, from its own needs (phase 3 and later).
