# Tower, part 1b: change models, roles and budgets

A project: the second part of `tower`, built after part 1a (`2026-11-05-tower-part-1a-design.md`), whose look, stack, login, data and tests it shares. Status: draft, 2026-11-05, written from a design conversation with the owner; not yet through the builder check or approved.

## Why

The settings the owner changes most often are which models are in the list and which model each role uses. Today that means editing `gateway/config.yaml`, running the price check, committing, pulling, restarting and running the smoke test, all by hand and in the right order. Model choices are the owner's own data, not code, so git is not their natural home. Part 1b lets tower make these changes, with the safety rules enforced in code instead of by memory (decided 2026-11-05, "Tower changes models, roles and budgets, with guard rails").

## Goals, non-goals and anti-goals

**Goals:**
1. Add, change and remove models and experiment names, and point each role at a model and host, from tower.
2. Change team and key budgets, and the OpenRouter key's monthly limit.
3. On every change, enforce `CLAUDE.md`'s rules, fetch the host's price, and prove the recorded spend with a test call before the switch.
4. Show each step live, log every change with old and new value, and export the whole setup.
5. Move the current 11 models out of `gateway/config.yaml` once, into the gateway's database.

**Non-goals:** an undo button (decided: the Log shows old and new values, and a change is reset by hand through the same editing); staged drafts applied together; changing Open WebUI's settings, ports or secrets (they need containers recreated; tower gets no access to Docker's socket); creating or deleting virtual keys or teams; the arena.

**Anti-goals:**
- A model live in the gateway that breaks a rule: no pin, fallbacks on, no zero data retention, a host outside the allowed four, or a price of zero or not the host's.
- Two entries with the same name, which LiteLLM load-balances (`provider-facts.md`), breaking the pin.
- A flow breaking without warning because a role it calls was removed.
- A limit raised without the owner seeing what it can cost.

## Constraints

Those of part 1a, and:
- The gateway runs with `store_model_in_db: true`; models live only in its database, never also in `gateway/config.yaml`.
- Tower writes models through LiteLLM's API (`/model/new`, `PATCH /model/{id}/update`, `/model/delete`) and budgets through its team and key API; the key limit through OpenRouter's management API. It never writes the gateway's database directly.
- `LITELLM_SALT_KEY` now encrypts stored model credentials, so the rule never to change it after the first start matters more; the README says so.

## Approaches considered

- **Where a model lives:** git only with tower showing it (the first choice), tower editing through the gateway's API with guard rails (**chosen**, revised by the owner the same day), or tower rewriting `config.yaml` and restarting the gateway (rejected: tower would need to restart the gateway, and the file and database would be two sources of truth).
- **When a change applies:** **straight away, tested before the switch (chosen)**; a staged draft applied in one go; applying first and undoing on a failed test (rejected: clients could hit a broken model meanwhile).
- **Undo:** a button per change (rejected by the owner as too much for what it gives); **old and new values in the Log, reset by hand (chosen)**.

## Making a change

Every change runs the same steps, each shown live on the page as it happens (`htmx`):

```
classify → mistral-small-3.2-24b @ DeepInfra fp8
  ✓ rules       one pinned host, fallbacks off, zero data retention, allowed host
  ✓ price       $0.075 / $0.20 per million, fetched from OpenRouter
  ◌ test call   1 call, at most $0.00006 …
  · switch      classify starts using the new model
  · logged
```

1. **Rules.** The entry names one model and one host tag, `order` and `only` set to that tag, `allow_fallbacks: false`, `zdr: true`, `data_collection: deny`, and a default `max_tokens`. The host is one of the account's allowed providers (CoreWeave, DeepInfra, SiliconFlow, Cloudflare; kept in tower's settings, as OpenRouter has no API for them). No `:free` variants.
2. **Price.** Fetched from OpenRouter's public `/api/v1/endpoints/zdr` for that model and tag: it must be listed (zero data retention), not in the flex tier, and without Safety Retention, as in the price check. The fetched price is what is stored; the owner cannot type a price.
3. **Cost shown and confirmed.** A new model or a model swap can cost money (`CLAUDE.md`), so tower shows its price and the test call's worst case before going on.
4. **Test call.** The new entry is added under a temporary name, the smoke-test call is made to it with `KEY_SMOKE_TEST`, and it must answer with a recorded cost above zero. If it fails, the temporary entry is removed, nothing changes for clients, and tower shows why.
5. **Switch.** The role or name moves to the new entry, and the old entry and the temporary name are removed, so there is never more than one entry per name.
6. **Keys.** Allowed names follow: a new experiment name is added to team `experiments` and its keys; a removed one is taken off; roles stay in team `permanent`'s and `node-red`'s lists.
7. **Logged** with time, what changed, the old and the new value side by side, and the test call's result and cost.

## Removing something in use

Before removing a model, role or experiment name, tower shows what uses it: which keys are allowed it and its calls this week. A role can be pointed at another model instead of being deleted. An experiment name can be removed, which also takes it off the keys' allowed lists. A role that a key in team `permanent` may call is never removed outright. Renaming a role is a removal plus an addition, under the same rule.

## Budgets and the key limit

- Tower keeps the order of limits: each key's budget within its team's, the teams within the gateway's global budget, the global budget below the OpenRouter key's monthly limit. A change that breaks it is refused, saying why.
- Raising a limit is flagged as able to cost money: old and new figure, and what it means for a month at full use, then a confirmation.
- Lowering one below this month's spend is allowed, with a warning.
- Changes apply at once: the key limit with `PATCH /api/v1/keys/{hash}` and the management key; team and key budgets through the gateway's `/team/update` and `/key/update`; the global budget through `/config/update` if it is not set in `config.yaml` (keys set there are locked), which decides where the global budget lives (left to the builder after trying it).
- `scripts/setup-keys.sh` stays for a fresh install and the terminal; it must not undo budgets set in tower without saying so. How the two stay consistent is for the builder, with the owner told the result.

## Starting set and export

- The 11 models move from `gateway/config.yaml` to `gateway/starting-set.yaml`, in the same format. `config.yaml` keeps the general settings only.
- Tower loads the starting set into the gateway's database **only when the database has no models**: on a fresh install, or once when 1b is deployed. Each entry goes through the same rules and price checks as a change; the test calls run as one smoke test, with its cost shown first. After that tower never reads the file again.
- The **export** writes the current models, roles, prices, pins and budgets in the same format, as a download. It can serve as a starting set for a rebuild, and as a snapshot kept with the backups.

## Testing

- **Level 1:** `pytest` for the rules, the price lookup, the order of limits and the removal rule; tower against the real LiteLLM image with `store_model_in_db: true` and the fake upstream, extended as in 1a. Covers: a change that passes; each rule broken; a failed test call leaving nothing changed; never two entries with one name; removing a role a `permanent` key may call is refused; the starting set loads once and only into an empty database; the export loads back as a starting set; no secret in any page, log or export.
- **First to try at level 1:** that `/model/new` and `PATCH /model/{id}/update` accept `extra_body.provider`, the per-token prices, `max_tokens` and custom `model_info` fields, and that the gateway records those prices; how a temporary name behaves for the test call.
- **Existing tests:** the level 1 tests load the starting set the same way; those that read `config.yaml` directly change to the gateway's API.
- **Level 2 and 3 (owner, on the Pi):** a test procedure written with the plan: the one-time move of the 11 models, with the smoke test; a role swapped from tower and called from Node-RED; a budget raised and lowered; the key limit changed and read back in OpenRouter's dashboard.

## Left to the builder

The editing forms and their layout within look B, the temporary name's format, how live progress is streamed (polling or server-sent events), the Log's schema additions, the export's file name, and where the global budget lives after trying `/config/update`.
