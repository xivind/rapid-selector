# Decisions and open questions

Decisions with their date and reason, the results of tests in practice, and what is still open. Facts about providers and tools are in `provider-facts.md`. Only what is of use to any home is kept here (2026-11-12); the step-by-step history is in git.

## Decided

### 2026-11-02: Monthly budget
**400 NOK** a month, including OpenRouter's 5.5% fee on credit purchases.

### 2026-11-03: The monthly cap is the key limit, not the top-up
Unspent credit carries over, so the maximum possible loss is the whole balance. The balance is kept small, and the monthly cap is the inference key's credit limit with a monthly reset. Reason: a monthly top-up does not cap monthly spend.

### 2026-11-03: `CLAUDE.md` is generic and stable
`CLAUDE.md` holds only what is always true. Requirements, roadmap, decisions and dated facts live in `docs/`. Reason: a `CLAUDE.md` that keeps changing is a moving target for every session.

### 2026-11-03: Log analysis is later
Not built now; what is needed first is that models can be called through the gateway's API with a virtual key. When it is built, what is sent may need cleaning first. Reason: logs can hold IP and MAC addresses, user names and household routines (principle 4).

### 2026-11-03: Overall design
- **Permanent use, not only a lab:** rapid-selector serves Node-RED and apps as well as experiments.
- **Models are an enhancement:** every flow must work without an answer, and the owner is told when calls fail. No automatic fallback to another model or host for now.
- **Fixed shares of the budget:** LiteLLM teams `permanent` and `experiments`; experiments can never use the permanent share.
- **The core works on its own; integrations are optional** (Prometheus and Grafana, a secret store, backup jobs, log shipping), switched on in configuration. Reason: others may use the repository.
- **Secrets are environment variables from a pluggable source:** `.env` by default, or a secret store through `rapidselector.sh`.
- **The allowlist** is LiteLLM's own config format, with roles for permanent use and `model@host` names for experiments, each with a default `max_tokens`.
- **Price drift** is caught by reconciliation against OpenRouter and by the price check.
- **Fixed host addresses** through DHCP reservations.
- **Programmatic use is an open category:** every new use gets its own key, calls a role, has its input checked for personal data, and is recorded here.

### 2026-11-03: Phase 0 design
- The inference key's variable is `RAPIDSELECTOR_OPENROUTER_KEY`, not the name LiteLLM looks for, so its `/openrouter` pass-through, which records $0 spend, finds no key.
- Virtual keys are generated in advance, stored as secrets, and registered by `setup-keys.sh`.
- `/metrics` is served without authentication, like `node_exporter`, on the LAN only.

### 2026-11-04: The request guard, volatile hosts, and an input limit for Node-RED
- **`gateway/request_guard.py`**, a small LiteLLM pre-call callback of our own, removes `extra_body`, `provider`, `models`, `route`, `transforms` and `fallbacks` from every request. Reason: a request body could otherwise replace the pin, zero data retention included, or add OpenRouter's fallback list.
- **A host whose price moves often is not pinned:** PrimeIntellect's price for `gpt-oss-120b` changed four times in a day, so CoreWeave took its place.
- **`node-red` has a token limit per minute** besides its call limit and budget. Reason: `CLAUDE.md` requires an input-size limit for automated clients.

### 2026-11-04: OpenRouter's account settings back up the pins
Auto top-up off, with no saved payment method. Under Data Policies, zero data retention on for every group, with **`ZDR only`** rather than the default `Allow Safety Retention`, which lets a host keep prompts for abuse prevention even with `provider.zdr: true` (`provider-facts.md`). Every training and publishing opt-in off, the 1% discount included. **Allowed Providers** limited to the hosts the allowlist uses, as a limit OpenRouter enforces; a new host needs a change there too (D5).

### 2026-11-05: No memory limits
Docker silently drops `mem_limit` where the kernel's memory control is off, as on Raspberry Pi OS by default, and warns at every start; turning it on changes the whole host. So `docker-compose.yml` sets none, and others who want them add them (README). To bring them back: 512m for `db` and 1536m each for `gateway` and `chat`, plus `cgroup_enable=memory cgroup_memory=1` in `/boot/firmware/cmdline.txt` and a reboot. The cost: nothing stops a leak in one container from filling the host.

### 2026-11-05: `up` is always detached
`docker compose up` stays attached without `-d`, and no Compose setting changes that (`provider-facts.md`), so `./rapidselector.sh up` adds `-d` itself.

### 2026-11-05: D1, the key limit stops calls, but late
The key limit is enforced against spend OpenRouter has already counted; calls started before that pass and are charged in full. At D1, five calls at a time took a $0.05 limit to $0.093, 86% past, before calls were refused with 403 `openrouter_key_limit`. **Accepted:** the key limit is a backstop, the gateway's budgets stay below it so the gateway stops first, and the balance is the hard cap and is kept small. The fast stop is disabling the inference key in OpenRouter's dashboard (README, "Stopping all spending").

### 2026-11-05: The key's monthly limit is $35
A round number below the monthly budget: credit plus the 5.5% fee plus 25% VAT ($5 of credit cost $7.25), so $35 fully used costs about 428 NOK. The gateway's global budget ($32) stays below it, so in normal use the gateway stops first. Raising or lowering it needs only OpenRouter's dashboard.

### 2026-11-05: The management key expires after a year
One year, the longest choice short of no expiry. OpenRouter's API does not give the expiry, so it is set in `.env` (`OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT`); `status.sh` warns 30 days before, and the README has the steps to make a new one.

### 2026-11-05: D5, the account refuses a host outside its list
A temporary entry pinned to a host without zero data retention and outside the allowed providers was refused by OpenRouter with 404, `failed_routing_step` "Filter by Allowed Providers", and nothing was charged; the gateway passed it on and tried no fallback. The data policy on its own could not be tested, since none of the allowed providers has an ordinary endpoint without zero data retention (only `:batch` variants, which the chat endpoint refuses).

### 2026-11-06: Chat runs Open WebUI's slim image, and its cache is not backed up
The standard image bundles embedding and Whisper models, loads the embedding model at every start whatever the settings say, calls Hugging Face at start, uses about 500 MiB more memory, and made the chat backup 1.1 GB. The slim image has none of that. The backup leaves out `/app/backend/data/cache`, which can always be rebuilt. The cost: no local voice input, and no `pandoc` or `ffmpeg` for files in chats.

### 2026-11-06: D6, the balance is not a hard stop at zero
Draining a $4.91 balance took it to **−$0.19**. OpenRouter's in-flight budget throttles calls as the balance runs out (402 `in_flight_budget_exhausted`), but let some through and charged them while the balance was already negative. So `CLAUDE.md`'s principle 1 reads "maximum possible loss = prepaid balance, plus a small overshoot", and says that "hard" means enforced by OpenRouter, not exact to the cent (2026-11-07). How far below zero it could go is unknown.

### 2026-11-08: Operator scripts instead of a service of our own
A web service of our own, tower, was built and dropped: it mostly re-presented what LiteLLM's admin UI, OpenRouter's dashboard and Grafana already show, and it kept the management key in a running container. In its place: curated scripts in `scripts/` (`status.sh`, `reconcile.sh`, `check-prices.sh` with the rules check, `setup-keys.sh`, `smoke-test.sh`, `write-metrics.sh` for Prometheus), documented for the owner and an agent alike, and the stack used as it is (principle 5). No kill switch script: OpenRouter's dashboard and LiteLLM's admin UI do that. `./rapidselector.sh restart gateway` refuses a config that breaks a rule.

### 2026-11-08: The management key is optional
Without it, everything starts and runs; `status.sh` and `reconcile.sh` stop with exit 3, and no cost figures reach Prometheus. What is lost is in `scripts/README.md`, "Without the management key". Reason: principle 2 is better kept by not demanding the most sensitive secret where it is not used.

### 2026-11-08: LiteLLM stays as the gateway
OpenRouter alone could do per-key budgets, one spend ledger and host limits. LiteLLM stays because: (1) its keys work only on the LAN, while a leaked OpenRouter key works from anywhere up to its limit; (2) the pin, `allow_fallbacks: false`, the default `max_tokens` and roles hold whatever the client sends; (3) one endpoint for local inference later; (4) its metrics allow continuous monitoring and alerts; (5) knowing a widely used tool is worth having; (6) rate limits per key. Not to be reopened without new facts.

### 2026-11-09: Remote access to the home network does not break principle 3
Reaching the home network from outside through a remote-access service on another device (here Raspberry Pi Connect, with two-factor authentication) is acceptable: the host itself runs no remote access, opens no port and publishes nothing to the internet. That service's account becomes one of the ways into the house, and must be protected as such.

### 2026-11-10: The config owns `store_prompts_in_spend_logs`, set to false
LiteLLM's admin UI has a switch that stores every prompt and answer in the spend logs, and so in Postgres and its backups; a value saved there applies unless the config declares the setting. So `config/gateway.yaml` sets `store_prompts_in_spend_logs: false`, guarded by a test. Reason: principle 4 should not hang on nobody clicking.

### 2026-11-11: A `config/` folder for each home's own settings
A home's allowlist (`config/gateway.yaml`) and budgets, limits and allowed providers (`config/home.env`) are ignored by git, beside examples in git: `scripts/` is what runs, `config/` is what is yours, and `.env` stays with the host and its secrets. `scripts/copy-config.sh` copies the two files over SSH, needed only when they are edited on another machine. Open WebUI's background calls go to the role **`chat-tasks`**, which each home points at its cheapest model. The rules check also checks `home.env`, including that the team budgets add up to at most the global budget. A home's settings keep no history.

### 2026-11-12: The docs keep what is of use, not the history
Docs hold what is of use to any home; a home's own facts go to that home's own repository, and the step-by-step history stays in git. Results go into "Tested in practice" below only when they add something (a new kind of test, or a different result). **A spec and its plan live only until their work is merged and verified**, then they are deleted.

## Tested in practice

What `CLAUDE.md` requires to be tested before a limit counts as working, and what was found. Dates are when it was seen; the host was a Pi 5 with 8 GB.

- **Key limit (D1), 2026-11-05:** stops calls only after their spend is counted; 86% past a $0.05 limit with five calls at a time. Only calls sent at the same time can show a call crossing a limit, and a 429 or 503 is not a limit working.
- **Balance (D6), 2026-11-06:** went to −$0.19 from $4.91; the in-flight budget throttles but does not stop at zero. New accounts are also limited to 20 calls a minute per model (429 `openrouter_new_account`).
- **Account's allowed providers (D5), 2026-11-05:** a host outside the list is refused with 404 before any charge.
- **Recorded spend and the pin, per name (D3, D4), 2026-11-05 and 06:** every name recorded a cost above zero, equal to OpenRouter's log to the last digit, and only the pinned host's price fits each call. An upstream 429 was passed on with no fallback. Since then each new name gets a smoke test with `--name`; `chat-tasks`, 2026-11-12. Adding and removing a model end to end, Open WebUI and Grafana included, rehearsed 2026-11-11.
- **The gateway's budgets (level 1, 2026-11-04, and every cloud run since):** key and team budgets stop within one call, with HTTP 422 `budget_exceeded`; the global budget lets a few calls too many through (0.05 let 4 calls, $0.06, on 2026-11-12), so the team budgets, which add up to it, are what stop spend promptly.
- **Database down (level 1, 2026-11-04):** LiteLLM fails closed: a spent key stays refused (422), other keys get 503, and calls work again once Postgres is back.
- **Rules check, 2026-11-09 and 2026-11-12:** `restart gateway` passes a valid config and refuses a broken rule (exit 5). After a `git pull` that moves the mounted file, a `restart` fails (finding 45); `up` is right.
- **Budget alerts (D8), 2026-11-06, and a threshold test, 2026-11-10:** the rules fired and their emails arrived. Test the email, not only the firing: at first the mail service accepted Grafana's emails, Gmail refused them, and Grafana counted them as sent.
- **Reboot (C5), 2026-11-06:** after `sudo reboot` the containers came back on their own, ports listening on the LAN address only, and the gateway was down about 1.5 minutes.
- **Memory (B5), 2026-11-05 and 06:** the stack takes about 1.3 GiB idle with Open WebUI's standard image; the slim image brought Open WebUI from about 857 to 344 MiB; LiteLLM uses 570–810 MiB.
- **Backups (E1), 2026-11-06:** the first nightly dumps of Postgres and Open WebUI's data ran; the restore is not yet tested (roadmap, parked).
- **Status and reconciliation, 2026-11-09:** `status.sh`'s figures matched OpenRouter's dashboard exactly, and `reconcile.sh` differed by at most $0.000004 per line. Cron, `write-metrics.sh`, `node_exporter`, Prometheus and Grafana worked end to end, every hour.
- **Level 1 on the Pi, 2026-11-04:** the suite passes on arm64, so the images run there.
- **Still to see:** the key limit's and the budgets' monthly reset (1 December).

## Open

### To settle later
- **Is an asynchronous layer such as MQTT needed at all?** Decided per use case, from its own needs (phase 3 and later).

### Findings, for the owner to decide
None blocks normal use. Numbers are kept from earlier lists.

20. Secrets are visible in `ps` on the host while the scripts run (curl headers and `-d` payloads). Could pass them on stdin (`curl -K -`, `--data @-`).
21. `POSTGRES_PASSWORD` goes into `DATABASE_URL`, so characters such as `@ / : # % ?` break the gateway. `.env.example` should say hex only.
22. Special characters in secrets are not tested through real `docker compose` and the secret store.
23. Secret store errors give only the HTTP status, not its meaning (401 token rejected, 423 secret deactivated, 404 unknown name).
24. The restart test accepts any non-200; it should assert 422 `budget_exceeded`.
25. The database-down test lacks a cached key with budget left.
30. README gaps: `setup-keys.sh` must be rerun after adding a model; rotating a `KEY_*` leaves the old key active; admin-UI edits to fields `setup-keys.sh` does not send stay.
32. `tests/run.sh` has no guard against a host running the real stack: the test stack uses the same container names, so starting it there fails. A guard could refuse with a clear message.
33. Two timing checks in `tests/drain.bats` expect calls within 1.5 seconds of each other, which may fail on slower arm64 hardware; widen them if they do.
34. `tests/drain-balance.sh --parallel` with no value exits 1 with no message (`shift 2` under `set -e`); the other value flags too.
35. `api` in `scripts/lib.sh` has no `--max-time`, so a hung gateway can block `drain-balance.sh`'s summary and the deletion of its temporary key.
36. Gaps in `tests/drain.bats`: no round mixes a fault with a limit refusal, or a limit with an in-flight refusal, and SIGINT is not tested, only TERM.
38. The gateway's log says "You are sending unauthenticated requests to the HF Hub", so LiteLLM fetches something from Hugging Face, probably a tokenizer. No prompt is involved as far as is known, but it is an outside call nobody chose: find out what, and whether it can be turned off or pinned.
39. LiteLLM retries 403, 429 and 503 twice by itself, so one client call can be three upstream, and six with the README's one client retry. Decide whether to set `num_retries`.
41. LiteLLM's admin UI warns that environment-credential login is a shared static secret, and suggests a personal admin account and `disable_env_credential_login: true`. Low risk on the LAN; check first how it affects the README's manual ways to stop spending.
45. `./rapidselector.sh restart gateway` after a `git pull` that moves the mounted config fails, and Docker leaves an empty, root-owned directory in its place: a restart reuses the container's old bind mount. The fix is `sudo rmdir` of it, then `up`. `rapidselector.sh restart` could compare the running container's mount source with the current path and refuse with "run `up`"; only a move of the config file triggers it, so it may not be worth code.
