# Operator scripts

The scripts that run rapid-selector day to day, for a person and an agent alike. Each one does one job, prints plain text, and says with its exit code whether all is well. Every script's header says the same as its row here, in more detail. For tasks rather than scripts (checking cost, changing a model, changing a budget), see [`docs/user-guide.md`](../docs/user-guide.md).

Run every script from the repository on the host. Scripts that need secrets run through `./rapidselector.sh run-script`, which loads them from `.env` or secrets-service first; the others run on their own.

## The scripts

| Script | What it does | When | Secrets | Cost | Exit codes |
|---|---|---|---|---|---|
| `status.sh [--prometheus]` | OpenRouter's balance, the inference key's limit and usage, a month forecast, the gateway's global and team budgets, the management key's expiry | Weekly, before a top-up, after an alert | `OPENROUTER_MANAGEMENT_KEY`, `KEY_SCRIPTS` | nothing | 0, 1 a warning, 2 |
| `reconcile.sh [--days N] [--prometheus]` | Per completed UTC day and model: LiteLLM's recorded spend against what OpenRouter charged; `!` marks a line off by more than $0.05 or 5% | Monthly, and a day after a model change | `OPENROUTER_MANAGEMENT_KEY`, `KEY_SCRIPTS` | nothing | 0, 1 a line flagged, 2 |
| `check-prices.sh [--rules-only] [config]` | Every entry in `gateway/config.yaml` against `CLAUDE.md`'s rules (offline), then its price and host against OpenRouter's zero data retention list (online) | Before every model change, and monthly | none | nothing | 0, 1 an entry fails, 2 the list cannot be read |
| `setup-keys.sh` | Creates or resets the teams and keys, with their budgets, names and routes | First setup, and after a name is added or removed | `LITELLM_MASTER_KEY` and the `KEY_*` | nothing | 0, 1 the gateway refused |
| `smoke-test.sh [--all \| --name <name>]` | One tiny call per role (or every name, or one), each recorded with a cost above zero; refusals checked too | First setup, after a model change or an upgrade | `LITELLM_MASTER_KEY`, `KEY_SMOKE_TEST` | **real money**: well under $0.01 for the roles, more with `--all` | 0, 1 a check failed or wrong usage |
| `write-metrics.sh [directory]` | Runs `status.sh` and `reconcile.sh` with `--prometheus` into node_exporter's textfile directory | Hourly from cron, extended mode only | as `status.sh` | nothing | 0, 2 a file not updated |
| `lib.sh` | Shared helpers and the only list of secret names. Sourced, not run | | | | 2, 3, 4 (below) |
| `jq/` | The jq programs that turn the raw answers into `status.sh`'s and `reconcile.sh`'s reports | | | | |

**One-off, to be deleted** once the owner has run them in `docs/test-procedures/ops-scripts.md`: `cleanup-tower-secrets.sh` (on the host, not through `run-script`) and `cleanup-tower-user.sh`.

`./rapidselector.sh` itself: `restart gateway`, and `restart` with no service, run `check-prices.sh --rules-only` first and exit `5` without restarting if a rule is broken.

## Exit codes

The same meaning for every routine script:

| Code | Meaning | What to do |
|---|---|---|
| 0 | All well | Nothing |
| 1 | Something needs a look: the output says what | Read it; `docs/user-guide.md` says what each warning means |
| 2 | A source could not be read, or wrong usage | The line starting `rapidselector:` names the source; try again later, or fix the command |
| 3 | A setting or secret is missing (`lib.sh`) | The line names it; fill it in `.env` or secrets-service |
| 4 | secrets-service unreachable or refusing (`lib.sh`, before the script starts) | Check secrets-service and its token file |
| 5 | `restart gateway` refused: `gateway/config.yaml` breaks a rule | Fix the entry named in the `FAIL` line; nothing was restarted |

A cron job or an agent treats every code other than 0 and 1 as "could not run". `write-metrics.sh` follows that rule: it still writes the figures on a warning, and keeps the old file when a script could not run, so Grafana sees the figures go stale.

## In what order

**First setup** (after the README's steps 1 to 4):
1. `./rapidselector.sh run-script scripts/setup-keys.sh`
2. `./rapidselector.sh run-script scripts/smoke-test.sh` (under $0.01)
3. `./rapidselector.sh run-script scripts/status.sh`

**A model change** (a new name, a role pointed at another model, a price):
1. Edit `gateway/config.yaml`.
2. `scripts/check-prices.sh`: the rules and the prices. Fix every `FAIL` line before going on.
3. Commit and push.
4. On the host: `git pull`, then `./rapidselector.sh restart gateway`, which checks the rules again and refuses (exit 5) if one is broken.
5. If a name was added or removed: `./rapidselector.sh run-script scripts/setup-keys.sh`.
6. `./rapidselector.sh run-script scripts/smoke-test.sh --name <name>`: a little real money, one call.
7. A day later: `./rapidselector.sh run-script scripts/reconcile.sh --days 1`, to see the new model's spend recorded correctly.

**Weekly, and before a top-up:** `status.sh`.

**Monthly:** `reconcile.sh` (the last 7 days by default; `--days 30` for the whole month), and `check-prices.sh`, since hosts change prices without notice.

## Two modes

- **Bare-bones:** secrets in `.env` (`SECRETS_SOURCE=env`), no Prometheus or Grafana. Run the scripts by hand in the order above; nothing watches continuously, and OpenRouter's key limit and balance are what stop spending. The management key then sits in `.env` beside the other secrets, so `.env` must be kept as safe as the key itself (`chmod 600`, and a copy away from the host).
- **Extended:** secrets from secrets-service (`SECRETS_SOURCE=secrets-service`), and `write-metrics.sh` from cron feeding Grafana's alerts and dashboard (README, "Optional: cost figures in Prometheus"). The alert rules and the dashboard live in the home's own repository; none of that applies in bare-bones mode.

Nothing in a script depends on the mode, except where its secrets come from, which `rapidselector.sh` handles.

## Tests

Test-only scripts live in `tests/`, not here: the bats suites, the fakes, `check-arm64.sh`, and `drain-balance.sh` (phase 0's balance test, which spends real money). The jq programs are tested without Docker in `tests/ops-logic.bats`; the scripts themselves at level 1 in `tests/ops-scripts.bats`, `tests/checks.bats`, `tests/rapidselector.bats` and `tests/cleanup.bats` (README, "For developers").
