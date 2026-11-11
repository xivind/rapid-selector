# User guide

The tasks done most often, one at a time, for the owner and an agent alike. Run every command from the repository on the host (`cd ~/code/rapid-selector`). Each script and its exit codes are described in [`scripts/README.md`](../scripts/README.md); first setup is in the [README](../README.md). This guide does not tour LiteLLM's admin UI or OpenRouter's dashboard beyond the step needed: `docs/onboarding.md` will.

Exit codes, in short: `0` all well, `1` read the output, `2` a source could not be read, `3` a missing setting or secret, `4` secrets-service, `5` `restart gateway` refused.

## Check cost and balance

**When:** weekly, before a top-up, and whenever a model feels slow or an alert arrives.

```bash
./rapidselector.sh run-script scripts/status.sh
```

**You should see:** OpenRouter's balance; the inference key's limit, what is left and when it resets; its usage today, this week and this month; a forecast for the month; the gateway's global budget and each team's spend and reset date; the management key's expiry. It ends with `No warnings.` (exit 0) or a list of warnings (exit 1, see [the last section](#a-warning-from-statussh-or-a-grafana-alert)). The balance and key figures should match OpenRouter's dashboard within a few cents.

**Cost:** nothing.

**Without the management key** (it is optional), `status.sh` exits 3 and says so: read the balance and the key's limit and usage in OpenRouter's dashboard instead, and the budgets in LiteLLM's admin UI ([`scripts/README.md`](../scripts/README.md#without-the-management-key)).

**If it fails:** exit 2 names the source that could not be read. `management key rejected (expired?)` means the management key has expired or is wrong: make a new one ([below](#a-warning-from-statussh-or-a-grafana-alert)). The gateway not answering: `./rapidselector.sh ps` and `./rapidselector.sh logs gateway`.

## The monthly check

**When:** once a month, and a day after any model change.

```bash
./rapidselector.sh run-script scripts/reconcile.sh --days 30
./rapidselector.sh run-script scripts/check-prices.sh
```

Without `--days`, `reconcile.sh` looks at the last 7 completed UTC days. Today is never included: OpenRouter reports only completed days. Without the management key, `reconcile.sh` does not run (exit 3), and only `check-prices.sh` is left of this check; comparing LiteLLM's usage with OpenRouter's activity page by hand is then the only reconciliation.

**You should see:** from `reconcile.sh`, a table of day, model, the gateway's recorded spend, OpenRouter's charge and the difference, a total per day, and `Nothing flagged.` (exit 0). Names that share a model (such as `chat` and `gpt-oss-120b@deepinfra`) are one line, because LiteLLM's daily table merges them. From `check-prices.sh`, `rules ok: 11 entries` and one `ok` line per entry (exit 0).

**Cost:** nothing.

**If it fails:** a line marked `!` (exit 1) is off by more than $0.05 or 5% of OpenRouter's figure. Small, one-off differences can come from a call that was cut off; a model that is off every day records the wrong price: check it with `check-prices.sh` and fix its price ([below](#point-a-role-at-another-model)). A `FAIL` line from `check-prices.sh` (exit 1) names the entry and what changed, usually a host's new price: update the price in `gateway/config.yaml` the same way. Exit 2 from `check-prices.sh`: OpenRouter's list could not be read; try again later.

## Add a model or an experiment name

**When:** to try a model, or the same model at another host. Experiment names have the form `model@host` and can be called by `chat` and the smoke test, not by Node-RED.

1. In `gateway/config.yaml`, copy an entry with `rapidselector_kind: experiment` and change its name, `model`, both prices, `max_tokens`, and the host tag in both `order` and `only` (e.g. `"deepinfra/fp8"`). The host must be one of the account's allowed providers (`ALLOWED_HOSTS` in `scripts/check-prices.sh`). Set `reasoning: true` for a reasoning model, and give it a larger `max_tokens`.
2. Check it, and fix every `FAIL` line:
   ```bash
   scripts/check-prices.sh
   ```
3. Commit and push. On the host:
   ```bash
   git pull
   ./rapidselector.sh restart gateway
   ./rapidselector.sh run-script scripts/setup-keys.sh
   ```
   `restart gateway` gives the prompt back before the gateway is ready: wait a few seconds, until `./rapidselector.sh ps` shows it `healthy`, or the next command fails with `Failed to connect`. `setup-keys.sh` gives team `experiments` (and so `chat`) the new name.
4. One call to it, which costs a little real money (a fraction of a cent for a small model):
   ```bash
   ./rapidselector.sh run-script scripts/smoke-test.sh --name <name>
   ```

**You should see:** `restart gateway` prints `rules ok: <n> entries` and restarts; the smoke test prints the name with `200` and a cost above zero, and ends with `OK`; Open WebUI lists the name after a page reload.

**Cost:** the smoke test call, and whatever you then spend in chat. A new model is something to flag before using it at length (`CLAUDE.md`).

**If it fails:** `restart gateway` exits 5 with a `FAIL` line naming the entry and the rule: fix it and restart again. A smoke test with cost 0 means a price is missing. The level 1 tests count the names in `gateway/config.yaml` (`tests/checks.bats`, for one), so a developer updates them with the change.

## Point a role at another model

**When:** a role (`classify`, `summarise`, `code`, `chat`) should use another model or host, or its host changed its price.

Edit that role's entry in `gateway/config.yaml` (model, prices, `max_tokens`, the tag in `order` and `only`), then follow steps 2 to 4 above, with `--name <role>` for the smoke test. The role keeps its name, so Node-RED and every other client go on calling it unchanged; `setup-keys.sh` is only needed if a name was added or removed.

**Cost and failures:** as above. A day later, `reconcile.sh --days 1` shows whether the new model's spend is recorded correctly.

## Add, rename or remove a role

**When:** a new kind of task needs its own stable name, or a role is no longer used.

- **Add:** a new entry with `rapidselector_kind: role`, then steps 2 to 4 above. `setup-keys.sh` adds the role to team `permanent`, so Node-RED's key may call it.
- **Rename or remove:** every client that calls the old name gets an error from the moment the gateway restarts. First find who calls it: Grafana's LLM dashboard, which counts per name, or LiteLLM's Logs page, one row per call (not the admin UI's usage view, which merges names sharing a model id); in Node-RED, every flow that calls it. Change them all at the same time as the gateway, or add the new name first, move the clients, and remove the old name last. Then run `setup-keys.sh`, which takes the old name off the keys' lists.
- Record the change in `docs/decisions.md` (a role is part of the clients' contract).

**Cost:** the smoke test call.

## Add a key for a new client

**When:** a new Node-RED flow family or app needs to call the gateway. Every automated client gets its own key, cap, call limit per run and maximum input size (`CLAUDE.md`, principle 1; `docs/requirements.md`, programmatic access).

This is a change to the repository, not a command: a new secret name (`KEY_<CLIENT>`) in `scripts/lib.sh`'s list and in `.env.example`, a new `ensure_key` line in `scripts/setup-keys.sh` in team `permanent` with its budget, rate limit and the roles only, and the value in `.env` or secrets-service (`echo "sk-$(openssl rand -hex 24)"`). Its budget comes out of team `permanent`'s, so check the order of limits ([next section](#change-a-budget)). Record the client, its key and its budget in `docs/decisions.md`. Then, on the host, `git pull` and `./rapidselector.sh run-script scripts/setup-keys.sh`; the new row appears in its summary.

**Cost:** nothing until the client calls.

## Change a budget

**When:** a team or key needs more or less.

The limits must stay in this order (`CLAUDE.md`, principle 1), from the top down:

1. OpenRouter's balance (the most you can lose), and the inference key's monthly limit (now $35, in OpenRouter's dashboard), the actual monthly cap.
2. LiteLLM's global budget (`max_budget` under `litellm_settings` in `gateway/config.yaml`, now $32), below the key limit.
3. The team budgets (`BUDGET_TEAM_PERMANENT` $8 and `BUDGET_TEAM_EXPERIMENTS` $24 at the top of `scripts/setup-keys.sh`), adding up to no more than the global budget.
4. The key budgets inside a team (`BUDGET_KEY_NODE_RED` $4, `BUDGET_KEY_SMOKE_TEST` $1), no more than their team's.

Change the value in the file, commit and push, then on the host `git pull` and either `./rapidselector.sh run-script scripts/setup-keys.sh` (teams and keys) or `./rapidselector.sh restart gateway` (the global budget). Raising a limit means more can be spent: flag it and record it in `docs/decisions.md`, with the date and the reason.

**You should see:** `setup-keys.sh`'s summary with the new figure; `status.sh` with the new budget.

**Cost:** nothing by itself.

## Top up the balance

**When:** `status.sh` warns that the balance is below $10, or before a month you expect to spend more.

First `status.sh`, to see the balance and the month's forecast. Then in OpenRouter's dashboard, buy credits (auto top-up stays off). Keep the balance small: it is the most you can lose. Record the top-up in `docs/decisions.md`.

**You should see:** `status.sh` with the new balance, and the balance warning gone.

**Cost:** the amount you buy, plus OpenRouter's fee.

## Stop all spending

**When:** something is spending that should not be, and you want it stopped now.

- **Everything, at once:** in OpenRouter's dashboard, disable the inference key (`rapidselector-gateway`). No call can reach any host after that. `status.sh` then warns that the key is disabled. Enable it again in the same place.
- **Without the dashboard:** stop the gateway on the host: `docker stop rapidselector-gateway`. Start it again with `./rapidselector.sh up`.
- **One client only:** block its key in LiteLLM's admin UI (`http://<host>:4000/ui`, Virtual Keys). The others go on working.

Afterwards, `reconcile.sh` and `status.sh` show what was spent, and the cause is recorded in `docs/decisions.md`.

**Cost:** nothing; it stops cost.

## Update the stack's images

**When:** a new release of LiteLLM, Open WebUI or Postgres is wanted.

Read the release notes first, and take a backup ([next section](#back-up-and-restore)). Change the version in `docker-compose.yml` (never `latest`), check that it exists for the Pi with `tests/check-arm64.sh`, run the level 1 tests in the cloud sandbox, commit and push. On the host:

```bash
git pull
./rapidselector.sh update
./rapidselector.sh ps
./rapidselector.sh run-script scripts/smoke-test.sh
```

**You should see:** the three services `healthy`, and the smoke test ending with `OK`.

**Cost:** the smoke test, under $0.01.

**If it fails:** `./rapidselector.sh logs <service>`; to go back, restore the old version in `docker-compose.yml` and run `update` again.

## Back up and restore

**When:** before an upgrade, and in any case nightly (with the owner's backup integration).

The README's "Backups" section has the commands for a backup without the integration. Keep the secrets with the backups: without `LITELLM_SALT_KEY`, a restored database cannot read its stored provider keys.

**Restore is not yet written or tested** (phase 0, step E2, `docs/test-procedures/phase-0-status.md`). Until it is, ask before restoring.

## A warning from `status.sh` or a Grafana alert

| Warning or alert | What it means | What to do |
|---|---|---|
| Balance below $10 (`status.sh`, or the Grafana alert) | Little credit left. OpenRouter then adds billing checks, so calls get slower and speed comparisons are unreliable | [Top up](#top-up-the-balance), or wait with speed comparisons |
| The inference key is disabled | Every model call fails | If you disabled it, enable it when ready; if not, look at OpenRouter's dashboard first |
| A budget above 80% spent | The global budget or a team's is close to its limit; calls are refused once it is reached | Look at what spent it (LiteLLM's admin UI, Usage); [raise the budget](#change-a-budget) only deliberately |
| A team resets on another day, or the key's limit does not reset monthly | OpenRouter's key limit and LiteLLM's budgets no longer reset together on the 1st | Check the key's reset in OpenRouter's dashboard (monthly), then run `setup-keys.sh` |
| The management key expires within 30 days, or has expired (`status.sh`, or the Grafana alert) | `status.sh` and `reconcile.sh` will stop working (exit 2) | Make a new management key in OpenRouter's dashboard with a one-year expiry; put it in secrets-service or `.env` (`OPENROUTER_MANAGEMENT_KEY`) and its date in `.env` (`OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT`); delete the old key |
| A day does not reconcile (`reconcile.sh`, or the Grafana alert) | A model's recorded spend differs from what OpenRouter charged | [The monthly check](#the-monthly-check), "If it fails" |
| Cost figures stale (Grafana) | `write-metrics.sh` has not updated `status.sh`'s or `reconcile.sh`'s figures for over 3 hours | Run `status.sh` by hand to see why; check the cron line and `journalctl -t rapidselector-metrics` |
| Gateway alerts (Grafana, group `LLM`) | A team budget nearly spent, failing calls, the gateway down, calls recorded without spend or at $0, database failures, or refused keys, as set up in phase 0 | Each alert's description says what to do |
