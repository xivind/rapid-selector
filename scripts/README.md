# Operator scripts

The scripts that run rapid-selector day to day, for a person and an agent alike. Each one does one job, prints plain text, and says with its exit code whether all is well. Every script's header says the same as its row here, in more detail. For tasks rather than scripts (checking cost, changing a model, changing a budget), see [`docs/user-guide.md`](../docs/user-guide.md).

**The rule: `scripts/` is what runs, the same for everyone; `config/` is what is yours.** Each home's models, roles, budgets, limits and allowed providers live in `config/gateway.yaml` and `config/home.env`, ignored by git ([`config/README.md`](../config/README.md)); the secrets stay in `.env`.

Run every script from the repository on the host, except `copy-config.sh`, which runs where you edit `config/`. Scripts that need secrets run through `./rapidselector.sh run-script`, which loads them from `.env` or secrets-service first; the others run on their own.

## The scripts

| Script | What it does | When | Secrets | Cost | Exit codes |
|---|---|---|---|---|---|
| `status.sh [--prometheus]` | OpenRouter's balance, the inference key's limit and usage, a month forecast, the gateway's global and team budgets, the management key's expiry | Weekly, before a top-up, after an alert | `OPENROUTER_MANAGEMENT_KEY` (optional, [below](#without-the-management-key)), `KEY_SCRIPTS` | nothing | 0, 1 a warning, 2 |
| `reconcile.sh [--days N] [--prometheus]` | Per completed UTC day and model: LiteLLM's recorded spend against what OpenRouter charged; `!` marks a line off by more than $0.05 or 5% | Monthly, and a day after a model change | `OPENROUTER_MANAGEMENT_KEY` (optional, [below](#without-the-management-key)), `KEY_SCRIPTS` | nothing | 0, 1 a line flagged, 2 |
| `check-prices.sh [--rules-only] [config]` | Every entry in `config/gateway.yaml` against `CLAUDE.md`'s rules, and `config/home.env`'s settings (team budgets no more than the global budget) (offline), then each entry's price and host against OpenRouter's zero data retention list (online) | Before every model or budget change, and monthly | none | nothing | 0, 1 an entry or setting fails, 2 a file or the list cannot be read |
| `setup-keys.sh` | Creates or resets the teams and keys, with their budgets and limits from `config/home.env`, names and routes | First setup, after a name is added or removed, and after a budget changed | `LITELLM_MASTER_KEY` and the `KEY_*` | nothing | 0, 1 a rule in `config/` broken (it runs the rules check first) or the gateway refused, 2 no `config/home.env` |
| `copy-config.sh to\|from [<user@host>]` | Copies `config/gateway.yaml` and `config/home.env` to the host over SSH (`to`, after the rules check), or from it (`from`, asking before it overwrites); never `.env` | After every change to `config/`; `from` to start on a second machine | none (`ssh` asks for the password) | nothing | 0, 1 a rule broken or answered no, 2 could not run |
| `smoke-test.sh [--all \| --name <name>]` | One tiny call per role (or every name, or one), each recorded with a cost above zero; refusals checked too | First setup, after a model change or an upgrade | `LITELLM_MASTER_KEY`, `KEY_SMOKE_TEST` | **real money**: well under $0.01 for the roles, more with `--all` | 0, 1 a check failed or wrong usage |
| `write-metrics.sh [directory]` | Runs `status.sh` and `reconcile.sh` with `--prometheus` into node_exporter's textfile directory | Hourly from cron, extended mode only | as `status.sh` | nothing | 0, 2 a file not updated |
| `lib.sh` | Shared helpers, the only list of secret names and the only list of `config/home.env` names. Sourced, not run | | | | 2, 3, 4 (below) |
| `jq/` | The jq programs that turn the raw answers into `status.sh`'s and `reconcile.sh`'s reports | | | | |

`./rapidselector.sh` itself: `restart gateway`, and `restart` with no service, run `check-prices.sh --rules-only` first and exit `5` without restarting if a rule is broken. Every command but `run-script` exits `2` when `config/gateway.yaml` or `config/home.env` is missing, naming the example to copy.

## Exit codes

The same meaning for every routine script:

| Code | Meaning | What to do |
|---|---|---|
| 0 | All well | Nothing |
| 1 | Something needs a look: the output says what | Read it; `docs/user-guide.md` says what each warning means |
| 2 | A source could not be read, or wrong usage | The line starting `rapidselector:` names the source; try again later, or fix the command |
| 3 | A setting or secret is missing (`lib.sh`) | The line names it; fill it in `.env` or secrets-service. For the optional management key, see [below](#without-the-management-key) |
| 4 | secrets-service unreachable or refusing (`lib.sh`, before the script starts) | Check secrets-service and its token file |
| 5 | `restart gateway` refused: `config/gateway.yaml` or `config/home.env` breaks a rule | Fix the entry or setting named in the `FAIL` line, copy it again; nothing was restarted |

A cron job or an agent treats every code other than 0 and 1 as "could not run". `write-metrics.sh` follows that rule: it still writes the figures on a warning, and keeps the old file when a script could not run, so Grafana sees the figures go stale.

## In what order

**First setup** (after the README's steps 1 to 4):
1. `./rapidselector.sh run-script scripts/setup-keys.sh`
2. `./rapidselector.sh run-script scripts/smoke-test.sh` (under $0.01)
3. `./rapidselector.sh run-script scripts/status.sh`

**A model change** (a new name, a role pointed at another model, a price):
1. Edit `config/gateway.yaml` where you keep it.
2. `scripts/check-prices.sh`: the rules and the prices. Fix every `FAIL` line before going on.
3. `scripts/copy-config.sh to`: no commit, as `config/` is yours and ignored by git.
4. On the host: `./rapidselector.sh restart gateway`, which checks the rules again and refuses (exit 5) if one is broken.
5. If a name was added or removed: `./rapidselector.sh run-script scripts/setup-keys.sh`.
6. `./rapidselector.sh run-script scripts/smoke-test.sh --name <name>`: a little real money, one call.
7. A day later: `./rapidselector.sh run-script scripts/reconcile.sh --days 1`, to see the new model's spend recorded correctly.

**Weekly, and before a top-up:** `status.sh`.

**Monthly:** `reconcile.sh` (the last 7 days by default; `--days 30` for the whole month), and `check-prices.sh`, since hosts change prices without notice.

## Two modes

- **Bare-bones:** secrets in `.env` (`SECRETS_SOURCE=env`), no Prometheus or Grafana. Run the scripts by hand in the order above; nothing watches continuously, and OpenRouter's key limit and balance are what stop spending. If you use the management key, it sits in `.env` beside the other secrets, so `.env` must be kept as safe as the key itself (`chmod 600`, and a copy away from the host); or leave it out ([above](#without-the-management-key)).
- **Extended:** secrets from secrets-service (`SECRETS_SOURCE=secrets-service`), and `write-metrics.sh` from cron feeding Grafana's alerts and dashboard (README, "Optional: cost figures in Prometheus"). The alert rules and the dashboard live in the home's own repository; none of that applies in bare-bones mode.

Nothing in a script depends on the mode, except where its secrets come from, which `rapidselector.sh` handles.

## Without the management key

OpenRouter's management key (`OPENROUTER_MANAGEMENT_KEY`) is **optional** (owner, 2026-11-08). It is the most sensitive secret in the system, since it can create, change and delete OpenRouter keys, so an installation that does not want it need not store it. Everything starts and runs without it. What you lose:

- **`status.sh` and `reconcile.sh` do not run.** They stop at once with exit 3 and a line saying the key is missing; they never call OpenRouter.
- **No balance and key figures in the terminal.** The balance, the inference key's limit, what is left and its usage are then read in OpenRouter's dashboard, and the gateway's budgets in LiteLLM's admin UI.
- **No reconciliation.** Nothing checks that each model records the spend OpenRouter actually charges (`CLAUDE.md`, principle 1). A wrong price in `config/gateway.yaml` then shows only when you compare LiteLLM's usage with OpenRouter's activity page by hand, or when a budget runs out earlier or later than it should. `check-prices.sh` still compares the prices with OpenRouter's public list before every change, which catches most such mistakes before they happen.
- **No warnings** for a balance below $10 (slower calls, unreliable speed comparisons), a disabled inference key, a budget above 80%, a reset-day mismatch, or the management key expiring.
- **In extended mode, no cost figures for Grafana.** `write-metrics.sh` writes no files and exits 2 every run, so leave its cron line out; Grafana's alerts on the balance, stale figures, reconciliation and the key's expiry then have nothing to watch. The gateway's own alerts (group `LLM`) work as before.

What still protects you is unchanged: OpenRouter's balance and the inference key's monthly limit, the gateway's budgets, the rules check before `restart gateway`, and the smoke test.

To add the key later: create it in OpenRouter's dashboard (Management API Keys, a one-year expiry), put it in `.env` or the secret `rapidselector` as `OPENROUTER_MANAGEMENT_KEY`, and set `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT` in `.env`. Nothing needs restarting: the scripts read it each time they run.

## Tests

Test-only scripts live in `tests/`, not here: the bats suites, the fakes, `check-arm64.sh`, and `drain-balance.sh` (phase 0's balance test, which spends real money). The jq programs are tested without Docker in `tests/ops-logic.bats`; the scripts themselves at level 1 in `tests/ops-scripts.bats`, `tests/checks.bats` and `tests/rapidselector.bats` (README, "For developers").
