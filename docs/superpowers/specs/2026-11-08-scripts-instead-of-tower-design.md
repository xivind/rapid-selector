# Scripts instead of tower

A project that replaces `tower` with a small set of curated operator scripts, their documentation and procedures, and cleans up what tower leaves behind. Status: draft for the owner, 2026-11-08, after the builder check. Replaces tower's designs and plans, which are deleted (owner: no historic documents kept just to keep them). Background: `docs/decisions.md`, "Tower paused; its place to be reconsidered" and the entry before it.

## Why

Tower part 1a mostly showed again what LiteLLM's admin UI, OpenRouter's dashboard and Grafana already show, and it was the only reason the OpenRouter management key sat in a running container. The owner wants to lean on well-known tools (LiteLLM, Open WebUI, later promptfoo) and learn them, rather than maintain a home-made interface. What tower did that no upstream tool does, the balance and a check that recorded spend matches what OpenRouter charged, is worth keeping, as scripts. Scripts and their documentation must serve both the owner and an agent (Claude, later perhaps Node-RED): plain output, stable exit codes, and a written order of use.

## Goals, non-goals and anti-goals

**Goals:**
1. `scripts/status.sh`: OpenRouter's balance, the inference key's limit and usage, LiteLLM's global and team spend against budget, and the management key's expiry, on one screen.
2. `scripts/reconcile.sh`: per day and per model, LiteLLM's recorded spend against OpenRouter's activity, flagging days that are off.
3. Both can print Prometheus text format, so a cron job can feed `node_exporter`'s textfile collector and Grafana can show and alert on the balance and the reconciliation.
4. A guarded model change: the rules from `CLAUDE.md` principle 1 and 4 checked on `gateway/config.yaml` before the gateway is restarted, with the existing price check.
7. Everything works in a bare-bones mode (`.env`, no Grafana) and an extended mode (secrets-service, Prometheus and Grafana).
5. Routine scripts in `scripts/`, test-only scripts in `tests/`, each with a header saying what it does and why, and `scripts/README.md` explaining how they fit together.
6. Tower removed everywhere: repository, `sandbox`, LiteLLM, secrets-service, `production`, this machine. What is worth keeping from `tower-part-1a` is carried over first.

**Non-goals:** a web page or a service of any kind; a kill switch script (the owner uses OpenRouter's dashboard for level 2 and LiteLLM's admin UI for level 1, as the README's "Stopping all spending" describes); per-name usage views (LiteLLM's admin UI and Grafana); benchmarking (promptfoo and Open WebUI's arena, a later brainstorm); the Grafana dashboard and alert rules themselves (`production`, after this).

**Anti-goals:**
- Scripts that grow into tower again: a script does one job; logic that needs more than a few hundred lines of bash is a sign to stop and ask.
- A script that can change the gateway's setup when it only means to read it.
- A secret in a process list, a URL, a log or the output.
- `scripts/` and `tests/` mixed again.

## Constraints

`CLAUDE.md` and the walkthrough rules in `docs/test-procedures/phase-0-status.md`, and in particular:
- The management key stays (owner, 2026-11-07), held in secrets-service only, fetched per run through `./rapidselector.sh run-script`, never in a container.
- `sandbox` has `jq` and `curl`, no Node and no Python tooling for us; scripts are bash with `jq`, like the existing ones.
- Commands the owner types stay short; anything longer is a committed script.
- `LITELLM_SALT_KEY` and the secret `rapidselector` must not be regenerated.

## Approaches considered

**What replaces tower:**
- **Tower narrowed to control** (cost, reconciliation, kill switch, metrics): rejected. It keeps a home-made service and the management key in a container for what is mostly convenience.
- **A small container running the scripts behind one page with buttons** (the owner's middle way; OliveTin looked at by the owner): rejected. The page must hold the management key or a secrets-service token (which unlocks every secret), a model change from a page needs Docker's socket, and OliveTin looked hacky to the owner.
- **Curated scripts with documentation and procedures** (**chosen** by the owner): the least code, the management key only borrowed per run, and the owner learns the upstream tools.

**How to clean up:**
- **A: a new branch from `phase-0-walkthrough`, bringing over only what is worth keeping** (**chosen**): clean history, every line traces to this change.
- **B: carry on from `tower-part-1a` and delete tower's parts:** rejected; history becomes "built, then removed", and leftovers are easy to miss.

## Decided by the owner

- Tower goes. LiteLLM's admin UI and Open WebUI are used as they are.
- The management key stays, for the balance and per-day reconciliation. No kill switch script.
- The scripts' gateway key is renamed and kept read-only, with role `proxy_admin_viewer` if that works.
- Routine scripts in `scripts/`, test-only scripts in a separate place; a header in every script; a README beside the scripts.
- Prometheus output and an hourly cron job feeding Grafana (owner: "That fits very well").
- Model-change guard, option c: `restart gateway` refuses on a broken rule; prices stay a step.
- Bare-bones and extended modes, both supported.
- Cleanup approach A. `tower-part-1a` is deleted when done, with no archive tag, and no tower document is kept: only the facts we need are carried over.
- `status.sh` warns below $10 of balance (see `status.sh`).
- A line in `CLAUDE.md` that the chosen stack covers our needs, with a reference to principle 5.

## The design

### Branch

A new branch `ops-scripts` from `phase-0-walkthrough`. `sandbox` switches to it for the owner's procedure. Merging order stays: `phase-0-walkthrough` into `main`, then `ops-scripts`. `phase-0-walkthrough` keeps getting records only (`decisions.md`, `phase-0-status.md`), as the walkthrough goes on; `ops-scripts` merges it in when it needs them. This project's procedure results are recorded there, and `phase-0-status.md` is rewritten there as the steps finish. (Claude's calls: the name, the order, and where records go.)

### Folders

- **`scripts/`**, run routinely: `lib.sh`, `setup-keys.sh`, `smoke-test.sh`, `check-prices.sh` (moved from `tests/`), `status.sh`, `reconcile.sh`, `README.md`.
- **`tests/`**, for testing only: the bats suites, the fakes, `check-arm64.sh`, and `drain-balance.sh` (moved from `scripts/`; it was built for D6's balance test). (Claude's call: `tests/` is already the testing folder, rather than a third one.) Paths in the bats suites, the README and the procedures follow the moves.
- Every script starts with a header: what it does and why, how to run it, which secrets it needs, what it costs, and what its exit codes mean.
- **`scripts/README.md`** explains for a person and an agent alike: which script to run when, in what order (first setup, a model change, the monthly check), what each one's output and exit codes mean, and where the procedures are. The main README links to it and keeps its "Everyday commands" short.

### Two modes: bare-bones and extended

Asked for by the owner, 2026-11-08: every part of this design works in both.
- **Bare-bones:** secrets in `.env` (`SECRETS_SOURCE=env`), no Prometheus or Grafana. The scripts print to the screen and are run by hand; `scripts/README.md` says when (`status.sh` weekly and before a top-up, `reconcile.sh` monthly, the model-change order on every change). Nothing watches continuously; the provider's hard limits are what stop spending, as before. The management key then sits in `.env` beside the other secrets, a trade-off the README states.
- **Extended:** secrets from secrets-service (`SECRETS_SOURCE=secrets-service`), and the Prometheus output fed by cron to `node_exporter`, with Grafana's alerts and dashboard (`production`).
- Nothing in a script depends on the mode except where its secrets come from, which `rapidselector.sh` already handles; `--prometheus` is the only switch for the extended output. One-off steps that touch secrets (the cleanup's secrets script) handle both: in bare-bones they print exactly which lines to add to or remove from `.env`, as `add-tower-secrets.sh` did. Level 1 runs in bare-bones mode (`test.env`); `tests/rapidselector.bats` with the fake secrets-service covers the extended secret source, and a test covers `--prometheus`.

### Exit codes (all routine scripts)

`0` all well; `1` something needs a look (the output says what); `2` a source could not be read, or wrong usage. `scripts/lib.sh` keeps its existing `4` for secrets-service unreachable or refusing, which happens inside `./rapidselector.sh run-script` before a script starts; `scripts/README.md` documents it, and the cron line and an agent treat any code other than 0 and 1 as "could not run". Existing scripts keep their codes, documented in the README. (Claude's call, after the builder check: no change to the wrapper.)

### The scripts' gateway key

- LiteLLM user `scripts` and key alias `scripts`, value in secret `KEY_SCRIPTS`, created by `setup-keys.sh` in place of tower's.
- Role `proxy_admin_viewer` if level 1 shows it can read `/user/daily/activity` for every user and `/global/spend` and `/team/info`; otherwise `proxy_admin`. Either way `allowed_routes` lists only the read routes the two scripts use (no `/key/block`, `/key/unblock`, `/model/info` unless needed). The key has no team, no budget and no model access.
- Level 1 asserts it is refused on `/key/generate`, `/key/update`, `/key/block`, `/model/new`, `/global/spend/reset`, `/v1/chat/completions` and the `/openrouter` pass-through.

### `status.sh`

Reads, with the management key: `GET /api/v1/credits` (balance = `total_credits` − `total_usage`) and the inference key's row (`GET /api/v1/keys?include_disabled=true`, matched by `OPENROUTER_INFERENCE_KEY_NAME`, then `GET /api/v1/keys/{hash}`): limit, remaining, usage today, this week and this month, `disabled`, and the limit's reset. With `KEY_SCRIPTS`: `/global/spend` (spend against the global budget) and `/team/info` for `permanent` and `experiments` (spend, budget, `budget_reset_at`). From `.env`: `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT`.

Prints one short screen in plain words: balance, key limit and usage, a month forecast (this month's usage ÷ days elapsed × days in the month), global and team spend against budget, reset dates, and the management key's days left. Exit `1` when: the balance is below $10 (a variable at the top; owner, 2026-11-08: OpenRouter adds billing checks and expires caches more aggressively at a single-digit balance or a key near its limit, so calls get slower, `provider-facts.md`; the output says so, since it also makes speed comparisons unreliable), the inference key is disabled, a team or the global budget is above 80% spent, OpenRouter's limit and LiteLLM's budgets do not reset on the same day (the requirement that a mismatch is visible), or the management key expires within 30 days. (Claude's calls: the 80% and 30 days.)

### `reconcile.sh`

Per completed UTC day (default the last 7, `--days N` up to 30, OpenRouter's limit) and per model id:
- Gateway side: `/user/daily/activity`, `breakdown.models` (keys of the form `openrouter/<model id>`), so names sharing a model id are added together by LiteLLM already. Per name or per host is not possible from this table (`decisions.md`, bug 2).
- OpenRouter side: `GET /api/v1/activity?api_key_hash=<inference key's hash>`, `usage` added over every `provider_name` (the full endpoint tag, e.g. `siliconflow/fp8`, bug 1) for the same `model`.
- A day and model is flagged when the difference is more than $0.05 or 5% of OpenRouter's figure, whichever is larger (tower's rule). A total line per day.
- Exit `1` if anything is flagged.

### Prometheus output

`status.sh --prometheus` and `reconcile.sh --prometheus` print Prometheus text format instead of the screen, prefixed `rapidselector_`: the balance, the key's limit, remaining and monthly usage, whether it is disabled, the management key's days left, the number of flagged days and the largest difference in the window, and the time of the run (so Grafana can see a stale file). Exact metric names are the builder's. Off unless asked for.

The README gets an optional-integration section: a cron line that runs both every hour through `./rapidselector.sh run-script` and writes to `node_exporter`'s textfile directory atomically (write to a temporary file, then `mv`). The real crontab on `sandbox`, the alert rules (balance low, file stale, a day flagged, management key expiring) and the dashboard go to `production`, after this project. `production`'s Pi unit already runs `node_exporter` with `--collector.textfile.directory=/var/lib/node_exporter/textfile`; that `sandbox` runs that unit is checked in the procedure.

### A guarded model change

`check-prices.sh` gains the static rules for every entry in `gateway/config.yaml`: `order` and `only` set to the same single tag, `allow_fallbacks: false`, `zdr: true`, `data_collection: deny`, a `max_tokens`, both prices above zero, the host one of the account's allowed providers (a list at the top of the script), no `:free` model and no wildcard. It still compares prices with OpenRouter's zero data retention list. The name may change to reflect the wider job (builder's call). The rules part needs no network and can run on its own (an option or a separate entry point, the builder's call).

**`./rapidselector.sh restart gateway` runs the rules check first and refuses to restart when a rule is broken** (the owner chose this, option c, 2026-11-08), saying which entry and which rule. The price comparison, which needs OpenRouter's list online, is not part of it, so a restart is never blocked by the network. Other `restart` targets and other commands are unchanged. Limit, accepted: a reboot or `up` still starts the gateway with whatever `config.yaml` holds; this guards the command that applies a change, not every path. `tests/rapidselector.bats` covers both outcomes.

`scripts/README.md` gives the order of a model change: edit `config.yaml` → the full check (rules and prices) → commit and push → on `sandbox`, `git pull` and `./rapidselector.sh restart gateway` (which checks the rules again) → `setup-keys.sh` if a name was added → `smoke-test.sh --name <name>` (its cost stated first).

### Carried over from `tower-part-1a`

- `scripts/lib.sh`: `api()` sending the key as a header file and the body on stdin; `OPENROUTER_MANAGEMENT_KEY` and `KEY_SCRIPTS` in the secrets list (not `TOWER_*`).
- `scripts/setup-keys.sh`: the key hash in URLs instead of the key value, the value through jq's environment, `auto_create_key: false`, and the read-only key (renamed).
- `.env.example`: `OPENROUTER_INFERENCE_KEY_NAME`, `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT`, `OPENROUTER_MANAGEMENT_KEY` (its comment rewritten: borrowed by the scripts), `KEY_SCRIPTS`. Not `TOWER_PORT`, `TOWER_PASSWORD`, `TOWER_SESSION_SECRET`.
- `tests/`: the fake upstream's OpenRouter management API, `tests/gateway-api.bats` adapted to the scripts' key, and the changes in `helpers.bash`, `keys.bats`, `fakes.bats`, `compose.*.yml` that these need. Not `tests/tower.bats`.
- `docs/provider-facts.md`: everything tower's branch added except "Tower dependencies" and "htmx"; plus bug 1 (activity's `provider_name` is the full tag) and bug 2 (LiteLLM's daily table merges names sharing a model id; its admin UI's usage view has the same limit).
- Not carried: `tower/`, tower's service in `docker-compose.yml`, `rapidselector.sh`'s tower build in `update`, `scripts/add-tower-secrets.sh`, `scripts/probe-key.sh`, tower's README sections, its test procedure and every tower spec and plan (`decisions.md`'s entries stand on their own), the `.gitignore` lines for tower.

### Docs that change

- `CLAUDE.md` (the owner's decision, made in this brainstorm): the architecture without `tower`, with a line that the chosen stack (LiteLLM, Postgres, Open WebUI, and later promptfoo for benchmarks) covers our needs, so we build no service of our own (principle 5, reuse before build); principle 2's exception becomes "the operator scripts borrow the management key from the secret store per run; no service holds it"; backups without tower's SQLite; the repo structure without `tower/`; "`tower` is the only interface we build" goes (we build none).
- `docs/requirements.md`: the `tower` section replaced by an "Operator scripts" section; general lines without tower.
- `docs/roadmap.md`: phase 1 becomes the scripts and this cleanup; arena and benchmarks no longer "build in tower"; the parked "tower engaging the kill switch by itself" removed or reworded.
- `README.md`: the `tower` port line removed; links to `scripts/README.md`.
- Deleted: `docs/superpowers/specs/2026-11-05-tower-part-1a-design.md`, `…/2026-11-05-tower-part-1b-design.md` and `docs/superpowers/plans/2026-11-06-tower-part-1a.md`. Tower's other documents exist only on `tower-part-1a` and go with it.

### Cleanup outside the repository (the owner's procedure)

1. On `sandbox`: stop and remove tower's container, image and SQLite volume; switch the clone to `ops-scripts`.
2. Secrets: a one-off committed script, like `add-tower-secrets.sh`, adds `KEY_SCRIPTS` and removes `TOWER_PASSWORD`, `TOWER_SESSION_SECRET` and `TOWER_GATEWAY_KEY` from the secret `rapidselector`, keeping every other field and printing names and lengths only. Deleted from the repository once run (Claude's call).
3. LiteLLM: `setup-keys.sh` creates user and key `scripts`; the user `tower` and its key are removed once (a one-off step; the means are the builder's).
4. `.env` on `sandbox`: `TOWER_PORT` removed; the two `OPENROUTER_*` lines stay.
5. `production`: the local branch `rapidselector-tower` deleted (never pushed, behind `main`).
6. This machine: the worktree `.worktrees/tower-part-1a` removed; `tower-part-1a` deleted locally and on GitHub, with no tag, once the carry-over is on `ops-scripts`.

## Testing

- **Level 1** (`tests/`, real images, fake upstream): `status.sh` and `reconcile.sh` against the fake's management API and the real gateway, each exit code shown by a test, `--prometheus` output parsed; the rules check against good and broken configs (one per rule); the scripts' key refused on every write route; `proxy_admin_viewer` tried first. A guessed response shape is what caused bug 1: the fake's activity rows use the shape seen on the real system (`provider_name` with the tag), and any shape not yet seen live is marked so in the test.
- **The owner's procedure on `sandbox`** (`docs/test-procedures/ops-scripts.md`), one step at a time: the cleanup steps above; `setup-keys.sh`; `status.sh` beside OpenRouter's dashboard (balance, limit, usage match); `reconcile.sh` for the last 7 days (the 11-05 and 11-06 lines for `gpt-oss-120b` now match); `check-prices.sh` on the live config; the smoke test (under $0.01); the textfile collector checked on `sandbox`. Nothing else costs money.

## Left to the builder

Metric names; the exact route list for the scripts' key; how the one-off removal of user `tower` is done; whether `check-prices.sh` is renamed; the layout of the output; how `reconcile.sh` pages through `/user/daily/activity`; the order of tasks, as long as the carry-over comes before the new scripts and every script is tested first.
