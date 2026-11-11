# Onboarding: LiteLLM's admin UI and OpenRouter's dashboard

A guided tour of the two web pages that sit beside rapid-selector's own tools: what each shows, what to look for, and what to leave alone. Do it in order, one step at a time. Checked against both sites' docs on 2026-11-10 (`docs/provider-facts.md`); Part 1 walked through with the owner on the real stack (LiteLLM v1.106.6) the same day, and corrected where the version differs from the docs.

**The one rule:** look here, change elsewhere. Budgets, keys and models are set by files and scripts in this repository (`scripts/setup-keys.sh`, `gateway/config.yaml`), and the next run of those puts back whatever was changed by hand. OpenRouter's settings are the exception: they live only in its dashboard, and every change there is recorded in `docs/decisions.md`.

**What the pages add to the scripts:** `scripts/status.sh` and `scripts/reconcile.sh` give the money on one screen, and Grafana alerts on it. The pages show the detail: single calls, single keys, and OpenRouter's own view of each request.

## Part 1: LiteLLM's admin UI

At `http://<host>:4000/ui` (the gateway's address, README "What runs").

### L1. Log in

- **Where:** the login page; afterwards you land on a home page. User `admin`, password `LITELLM_UI_PASSWORD`, which you read in secrets-service's admin UI, secret `rapidselector` (or your password manager). Never paste it anywhere else.
- **Look for:** a yellow warning about "Environment-credential login" (it can be closed). It means anyone with that one shared password is a full admin. Here that is you, on the LAN, with a long random password, so it is accepted for now (finding 41 in `docs/decisions.md`). The fix LiteLLM suggests, a personal admin account and `disable_env_credential_login: true`, locks the UI if done in the wrong order; it stays a separate decision.
- **Good to know:** each login creates a hidden session key for the UI, valid for 24 hours with a $1 budget, which no key list shows (`provider-facts.md`). More than 10 wrong passwords in a minute lock you out for 5 minutes.
- **Don't change:** anything under **Internal Users** or **Settings**.

### L2. Usage

- **Where:** **Usage** in the menu, global view.
- **Look for:** spend, requests and tokens per day, per key and per model. The month's total should match `status.sh`'s "Global budget … spent".
- **Known limit:** names that share an OpenRouter model id are merged into one row, for example `chat`, `gpt-oss-120b@deepinfra` and `gpt-oss-120b@coreweave` are all `openai/gpt-oss-120b`. Totals and per-key figures are right; per name they are not (`provider-facts.md`). Grafana's LLM dashboard counts per name correctly.
- **Don't change:** nothing to change here.

### L3. Virtual Keys

- **Where:** **Virtual Keys**.
- **Look for:** `chat`, `node-red`, `smoke-test` and `scripts`, each with its team, budget, spend and the names it may call: `node-red` the 4 roles, `chat` and `smoke-test` all 11. `chat` has no budget of its own; its team's is its cap. L1's session key does not show.
- **"All Proxy Models" on `scripts`** is expected: an empty list means no model restriction, and what stops that key from calling models is its route list (three read routes only), tested at level 1.
- **The one thing to do here:** **block** a key to stop one client and keep the others running (README, "Stopping all spending"). Unblock it the same way.
- **Don't change:** budgets, models, limits or routes. `setup-keys.sh` is the source of truth: an edit here works until its next run, which silently puts it back. Change the numbers in that script and run it instead (user guide, "Change a budget").

### L4. Teams

- **Where:** **Teams**.
- **Look for:** `permanent` ($8) and `experiments` ($24) and their spend. They add up to the global budget, $32. The page shows the budget's length, `30d`, not the next reset; `status.sh` prints that (the 1st of next month).
- **Don't change:** the same as keys: `setup-keys.sh` owns them.

### L5. Models

- **Where:** **Models + Endpoints**, All Models.
- **Look for:** the 11 names, each with a **config** badge and "Defined in config" as creator, and their prices and host pins. No edit option: LiteLLM never edits models from the file, and our `store_model_in_db: false` turns off models in the database.
- **Don't change:** you can't: models from `config.yaml` are read-only here, and **Add model** fails, since `store_model_in_db` is off. A new model goes through `config.yaml`, `scripts/check-prices.sh` and `./rapidselector.sh restart gateway` (user guide, "Add a model or an experiment name").

### L6. Logs

- **Where:** **Logs**.
- **Look for:** one row per call: time, key, model, status, tokens and cost. A failed call shows its error here first. Kept for 90 days.
- **Content is not stored:** only these facts about each call, not what was asked or answered. That is LiteLLM's default.
- **Storing content is locked off:** the switch "Store Prompts in Spend Logs" lives in **Admin Settings, "Logging Settings"** (not on the Logs page in v1.106.6). Since 2026-11-10, `config.yaml` declares `store_prompts_in_spend_logs: false`, so the file owns the setting and the switch is ignored (the gateway reports `"source": "config"`). Leave it off all the same.

## Part 2: OpenRouter's dashboard

At openrouter.ai, signed in.

### O1. Credits

- **Where:** **Credits**.
- **Look for:** the balance, which should match `status.sh`'s; auto top-up **off**, and no saved card.
- **Good to know:** a purchase can be refunded within 24 hours; OpenRouter may expire credit unused for a year. Both are reasons to keep the balance small (`CLAUDE.md`, principle 1).
- **Don't change:** never turn on auto top-up. A top-up is a decision recorded in `docs/decisions.md`.

### O2. Keys

- **Where:** **Keys**, under **Workspace** in the menu (OpenRouter's docs still point to `/settings/keys`).
- **Look for:** `rapidselector-gateway`, the gateway's only inference key: limit $35, monthly reset, and its usage.
- **The one thing to do here:** **disable** it to stop all spending at once, the fast stop (README, "Stopping all spending"). Enable it again the same way; for a few seconds after that, the gateway may still answer 429 while it cools down.
- **Don't change:** the limit (a recorded decision), and never delete the key: its value lives in secrets-service, and a new key means a new value there.

### O3. Management keys

- **Where:** **Settings, Management keys**, a list of its own.
- **Look for:** `rapidselector-scripts`, expiring 2027-11-07. Grafana warns 30 days before.
- **Don't change:** it can create and delete keys, so treat it as the most sensitive secret. A new one always gets an expiry.

### O4. Activity

- **Where:** **Activity**.
- **Look for:** usage per day, filterable by model, provider and key. This is the other side of `reconcile.sh`: a day it flags is the day to look at here.
- **Good to know:** the filters also list routers (Auto Router, Auto Code, Jev Router). A router picks the model for a call that names it as its model. None of the gateway's names is a router, so rapid-selector uses none (`provider-facts.md`).

### O5. Privacy and providers

- **Where:** **Settings, Privacy**, and **Observability** in the workspace settings.
- **Look for:**
  - zero data retention on for every group, with "ZDR only" under "All other models" and "Google";
  - under "Data Training", all four switches **off**: paid endpoints that train on request data, free endpoints that train on it, free endpoints that publish prompts, and "Allow 1% data discount in workspaces", the account's master switch for OpenRouter using inputs and outputs (each workspace would consent separately on top);
  - "Private Input & Output Logging" under Observability **off**;
  - allowed providers: Cloudflare, CoreWeave, DeepInfra and SiliconFlow.
- **Don't change:** any of it without a decision in `docs/decisions.md`. A new provider also means new allowlist entries and `scripts/check-prices.sh`'s `ALLOWED_HOSTS`.

### O6. Account security

- **Where:** **Account, User, Security**.
- **Look for:** two-factor authentication **on** (turned on 2026-11-11). If you sign in with Google or GitHub, the second factor belongs on that account too.

## Part 3: rehearse adding and removing a model

The owner's wish (2026-11-11): do it once together, with a real new model, so the steps are known before they are needed. A candidate: Google's newest Gemma, whatever OpenRouter lists when we get here (checked then, not from memory).

### R1. Pick it

- **Check first:** the model is on OpenRouter with an endpoint at one of the four allowed providers that has zero data retention, not in the flex tier and without Safety Retention, and its price at that host. If none qualifies, pick another model; a fifth provider is a decision of its own.
- **Cost, flagged before anything runs:** the smoke test's one call to it, a fraction of a cent for a small model, and whatever is then spent trying it in chat.

### R2. Add it

Follow the user guide, "Add a model or an experiment name", as an experiment name (`model@host`): the entry in `gateway/config.yaml`, `scripts/check-prices.sh`, commit, then on the host `git pull`, `./rapidselector.sh restart gateway` and `setup-keys.sh`, and one smoke-test call with `--name`. Then see it in Open WebUI, LiteLLM's Models page (12 names) and, after a call, Grafana's LLM dashboard.

### R3. Remove it

The reverse: delete the entry, `check-prices.sh`, commit, `git pull`, `restart gateway`, `setup-keys.sh` (which takes the name off the keys' lists). Then confirm it is gone from Open WebUI and the Models page, and that `smoke-test.sh --name <name>` stops with "the gateway has no name", without a call. Its past spend stays in the usage and logs. Record both in `docs/decisions.md`.

Done on 2026-11-11 with Gemma 4 31B at DeepInfra (`gemma-4-31b@deepinfra`): added, one smoke-test call ($0.0000046), removed.

## Where each change is made

| To change | Where |
|---|---|
| A key's or team's budget, a key's names or rate limit | `scripts/setup-keys.sh`, then run it (user guide) |
| A model, its price or host | `gateway/config.yaml`, `scripts/check-prices.sh`, `./rapidselector.sh restart gateway` |
| The monthly cap | the inference key's limit in OpenRouter (O2), recorded in `docs/decisions.md` |
| Stop one client | block its key (L3) |
| Stop everything | disable the inference key (O2), or `docker stop rapidselector-gateway` |
| Privacy, providers, top-up | OpenRouter's settings (O1, O5), recorded in `docs/decisions.md` |
