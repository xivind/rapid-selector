# Tower, part 1b: change models, roles and budgets

A project: the second part of `tower`, built after part 1a (`2026-11-05-tower-part-1a-design.md`), whose look, stack, login, data and tests it shares. Status: draft, 2026-11-05, written from a design conversation with the owner; through the builder check, the owner's answers written in; awaiting the owner's approval.

## Why

The settings the owner changes most often are which models are in the list and which model each role uses. Today that means editing `gateway/config.yaml`, running the price check, committing, pulling, restarting and running the smoke test, all by hand and in the right order. Model choices are the owner's own data, not code, so git is not their natural home. Part 1b lets tower make these changes, with the safety rules enforced in code instead of by memory (decided 2026-11-05, "Tower changes models, roles and budgets, with guard rails").

## Goals, non-goals and anti-goals

**Goals:**
1. Add, change and remove models and experiment names; create, rename and remove roles and point each at a model and host; and choose which names each team and key may call, from tower.
2. Change team and key budgets, and the OpenRouter key's monthly limit.
3. On every change, enforce `CLAUDE.md`'s rules, fetch the host's price, and prove the recorded spend with a test call before the switch.
4. Show each step live, log every change with old and new value, and export the whole setup.
5. Move the current 11 models out of `gateway/config.yaml` once, into the gateway's database.

**Non-goals:** an undo button (decided: the Log shows old and new values, and a change is reset by hand through the same editing); staged drafts applied together; changing Open WebUI's settings, ports or secrets (they need containers recreated; tower gets no access to Docker's socket); creating or deleting virtual keys or teams; aliases that keep an old role name working after a rename; the arena.

**Anti-goals:**
- A model live in the gateway that breaks a rule: no pin, fallbacks on, no zero data retention, a host outside the allowed four, or a price of zero or not the host's.
- Two entries with the same name, which LiteLLM load-balances (`provider-facts.md`), breaking the pin.
- A flow breaking without warning because a role it calls was removed or renamed.
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
6. **Keys.** Allowed names follow, and the temporary name is allowed for the smoke-test key during the test call only: a new experiment name is added to team `experiments` and its keys; a removed one is taken off; roles stay in team `permanent`'s and `node-red`'s lists.
7. **Logged** with time, what changed, the old and the new value side by side, and the test call's result and cost.

## Experiment names

An experiment name is always built from its model and host, `<model>@<host>`, so it tells the truth. Moving an experiment to another host is therefore a removal and an addition. A name that Open WebUI uses for titles (`TASK_MODEL_EXTERNAL` in `docker-compose.yml`, which tower reads) cannot be removed from tower; the page says to change `docker-compose.yml` first. (Claude's calls.)

## Where the key comes from

New entries refer to the OpenRouter key as `os.environ/RAPIDSELECTOR_OPENROUTER_KEY`, which the gateway resolves itself, so tower never holds the key. **If level 1 shows that v1.106.6 does not resolve that reference for models stored in its database, the build stops and the owner decides**: a stored LiteLLM credential risks handing the `/openrouter` pass-through, which records $0 spend, a real key again, and giving tower the key breaks `CLAUDE.md`'s principle 2.

## Roles and allowed names

Full editing of roles, decided by the owner (option B; A was pointing roles at models only, with removing and renaming done in the terminal).

- **Create a role:** a lower-case name without `@`, so it cannot be mistaken for an experiment name, and not already in use. Its model and host go through the steps in "Making a change". It is then added to team `permanent`'s allowed names; which keys get it is chosen in the same form.
- **Point a role at another model:** the steps in "Making a change".
- **Rename a role:** tower first shows what calls the old name (the keys allowed it, and its calls this week), and that every client calling it must be changed, since the old name stops working at once. With the new name typed to confirm, tower creates the new role on the same entry, moves it into every list that had the old one, and removes the old name. No alias is kept.
- **Remove a role:** the same "what uses it" screen, and the role's name typed to confirm. It is then taken off every allowed list and removed. A name Open WebUI uses for titles (`TASK_MODEL_EXTERNAL`, which tower reads from `docker-compose.yml`) cannot be removed or renamed from tower; the page says to change `docker-compose.yml` first.
- **Allowed names:** for each team and each key, the names it may call, chosen from the current roles and experiment names. A key's names must be within its team's. Team `permanent` and its keys may hold roles only (`CLAUDE.md`: clients call roles); team `experiments` may hold both. Each change is logged with the old and new list.

## Removing a model or an experiment name

Before removing a model or an experiment name, tower shows what uses it: which keys are allowed it and its calls this week. A model behind a role can only be replaced, not removed, while the role exists. An experiment name can be removed, which also takes it off the keys' allowed lists.

## Budgets and the key limit

- Tower keeps the order of limits: each key's own budget at most its team's; the team budgets added together at most the gateway's global budget (today 8 + 24 = 32); the key budgets that are set, added together, at most the global budget (`CLAUDE.md`; today 4 + 1); and the global budget strictly below the OpenRouter key's monthly limit (today 32 < 35). A key without a budget of its own, such as `chat`, uses its team's and is not counted in the sums. A change that breaks this is refused, saying why. (Claude's reading, which today's setup meets.)
- Raising a limit is flagged as able to cost money: old and new figure, and what it means for a month at full use, then a confirmation.
- Lowering one below this month's spend is allowed, with a warning.
- Changes apply at once: the key limit with `PATCH /api/v1/keys/{hash}` and the management key; team and key budgets through the gateway's `/team/update` and `/key/update`; the global budget through `/config/update` if it is not set in `config.yaml` (keys set there are locked), which decides where the global budget lives (left to the builder after trying it).
- `scripts/setup-keys.sh` stays for a fresh install and the terminal; it must not undo budgets set in tower without saying so. How the two stay consistent is for the builder, with the owner told the result.

## Starting set and export

**The one-time move, without an outage** (Claude's call): tower loads the 11 models into the database while `config.yaml` still has them. The database entries are identical to the file's, same pin and price, so LiteLLM's load-balancing between the two copies sends every call to the same host. Only when all 11 have loaded and passed does `config.yaml`'s model list go and the gateway restart, so there is never a moment without roles. If any entry fails, tower removes what it loaded and nothing changes; the owner is told which entry failed and why.

**Prices on loading** (Claude's call): the price is fetched from OpenRouter, as for any change. Where it differs from the file's, tower lists the differences before loading and asks for confirmation; an old export therefore loads at today's prices, with the changes shown.

**Test calls on loading** use the gateway's master-key access through tower's own key, not `KEY_SMOKE_TEST`, so a fresh install does not need `setup-keys.sh` to have run first. (Claude's call.)

**Budgets in an export** are applied when it is loaded as a starting set; a fresh install without an export uses `setup-keys.sh`'s figures. (Claude's call.)

- The 11 models move from `gateway/config.yaml` to `gateway/starting-set.yaml`, in the same format. `config.yaml` keeps the general settings only.
- Tower loads the starting set into the gateway's database **only when the database has no models**: on a fresh install, or once when 1b is deployed. Each entry goes through the same rules and price checks as a change; the test calls run as one smoke test, with its cost shown first. After that tower never reads the file again.
- The **export** writes the current models, roles, prices, pins and budgets in the same format, as a download. It can serve as a starting set for a rebuild, and as a snapshot kept with the backups.

## Testing

- **Level 1:** `pytest` for the rules, the price lookup, the order of limits and the removal rule; tower against the real LiteLLM image with `store_model_in_db: true` and the fake upstream, extended as in 1a. Covers: a change that passes; each rule broken; a failed test call leaving nothing changed; never two entries with one name; removing a role a `permanent` key may call is refused; the starting set loads once and only into an empty database; the export loads back as a starting set; no secret in any page, log or export.
- **First to try at level 1:** that a database model with `api_key: os.environ/RAPIDSELECTOR_OPENROUTER_KEY` is resolved by the gateway and the `/openrouter` pass-through stays refused; that `/model/new` and `PATCH /model/{id}/update` accept `extra_body.provider`, the per-token prices, `max_tokens` and custom `model_info` fields, and that the gateway records those prices; how a temporary name behaves for the test call.
- **Existing tests:** the level 1 tests load the starting set the same way; those that read `config.yaml` directly change to the gateway's API.
- **Level 2 and 3 (owner, on the Pi):** a test procedure written with the plan: the one-time move of the 11 models, with the smoke test; a role swapped from tower and called from Node-RED; a budget raised and lowered; the key limit changed and read back in OpenRouter's dashboard.

## Left to the builder

How the switch is done (for example updating the entry in place with the tested settings, so a name never has two entries or none), refusing test calls while kill switch level 1 is engaged, clearing temporary entries left after a crash, pointing `tests/check-prices.sh` at the gateway's API, the routes tower's gateway key needs, the editing forms and their layout within look B, the temporary name's format, how live progress is streamed (polling or server-sent events), the Log's schema additions, the export's file name, and where the global budget lives after trying `/config/update`.
