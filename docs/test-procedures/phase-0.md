# Phase 0: test procedure for levels 2 and 3

We go through this together: Claude walks you through each step, you say what you saw, and Claude records the results in `docs/decisions.md`. Do not run ahead: some steps spend real money, and a step whose result looks wrong is where we stop and look.

**Cost ceiling:** at most **$1 plus the smallest top-up**. The smallest top-up is spent on purpose in step D6. **Stop rule:** if OpenRouter's activity log shows more spent than the step's stated cost, stop and tell Claude before the next step.

**Where:** on `sandbox`, in the repository clone. Commands are run in that folder.

## A. OpenRouter preparation (in OpenRouter's dashboard)

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| A1 | Settings: turn auto top-up **off**. Privacy: prompt logging and every opt-in to data collection **off**. Zero data retention **required** for the account: every toggle on, with `ZDR only`, not `Allow Safety Retention`, under "All other models" and "Google". If the account has an allowed-providers list, limit it to the hosts in `gateway/config.yaml` (DeepInfra, CoreWeave, SiliconFlow, Cloudflare). These are the backstop if a request ever gets past the gateway's pin | The settings saved | Which of these you found, and their exact wording. If zero data retention cannot be required for the account, stop and tell Claude | 0 |
| A2 | Keys: create the gateway's inference key, named e.g. `rapidselector-gateway`, with a credit limit of **$0.05**, reset **monthly** | The key, shown once | That it exists, its limit and reset. Put the key in the secrets as `RAPIDSELECTOR_OPENROUTER_KEY` | 0 |
| A3 | Credits: buy the **smallest top-up** offered | The balance | The amount paid, the 5.5% fee, and the balance | the top-up |

## B. Level 2 on `sandbox` (little or no money)

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| B1 | Clone the repository, `cp .env.example .env`, fill in the settings (`RAPIDSELECTOR_LAN_ADDRESS` = sandbox's address, `SECRETS_SOURCE=secrets-service`, the token file). `chmod 600 .env` and the token file. Generate the secrets with the commands in `.env.example` (hex only: other characters break `DATABASE_URL`) and store them as the secret `rapidselector` in secrets-service | | That the secret exists with all 9 fields (names only, never values) | 0 |
| B1a | Install `jq` if it is missing. Without Node on the host, fetch the test runner: `git clone --depth 1 --branch v1.11.0 https://github.com/bats-core/bats-core.git ~/bats-core`. Run `~/bats-core/bin/bats tests/*.bats 2>&1 \| tee ~/level1.log`, then `grep -c '^ok' ~/level1.log; grep '^not ok' ~/level1.log`. **Only here, before B2:** the tests use the same container names as the real stack, so they cannot run beside it | A count of passed tests and no `not ok` lines. Takes about 25 minutes, plus the first image download of about 1.9 GB | Both results | 0 |
| B2 | `free -h`, to note the memory in use. Then `./rapidselector.sh up`, and `./rapidselector.sh ps` after a few minutes | `rapidselector-db`, `rapidselector-gateway` and `rapidselector-chat`, all `healthy` | The `free -h` and `ps` output | 0 |
| B3 | `./rapidselector.sh run-script scripts/setup-keys.sh` | A table with 2 teams and 3 keys: `permanent` 8, `experiments` 24, `node-red` 4, `chat` team, `smoke-test` 1 | The table | 0 |
| B4 | Open `http://sandbox:4010`, create the admin account | Open WebUI, with the 11 names in the model list | That it worked and the names are there | 0 |
| B5 | `free -h`, then `ps -eo rss,comm --sort=-rss \| head -15`. `docker stats` shows no memory where the kernel's memory control is off | Memory in use compared with B2, and the biggest processes | Both outputs. Claude records whether the stack fits | 0 |
| B6 | `./rapidselector.sh run-script scripts/smoke-test.sh` | Four roles with status 200 and a cost above zero, two `refused:` lines, `OK` | The output | under $0.01 |

## C. `production` repository (warnings and backups before money is spent)

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| C1 | The `production` changes are already merged (#181). Pull them where Prometheus runs, and restart Prometheus | Target `rapidselector-gateway` is `up` in Prometheus | Target status | 0 |
| C2 | In a local Claude Code session in the `production` repository (with `GRAFANA_MCP_TOKEN` set), create the alert rules from `grafana/rapidselector-alerts.md` through the Grafana MCP | The rules in folder **Alerts**, group **LLM** | That they exist | 0 |
| C3 | Install the forced-command SSH key for the backup jobs on `sandbox`, as described in `backup-orchestrator/README.md` | | That it is installed | 0 |
| C4 | Node-RED already has `sandbox` in its `--add-host` list. On `messagebroker`: `docker exec nodered wget -qO /dev/null http://sandbox:4000/metrics/ && echo gateway reachable` | `gateway reachable` | The result | 0 |
| C5 | **Reboot check.** `sudo reboot`. When sandbox is back, wait 10 minutes (chat takes a few minutes to start). Then `ss -tln '( sport = :4000 or sport = :4010 )'` and `./rapidselector.sh ps`, and look at the alert rules | Both ports listen on sandbox's LAN address only, never `0.0.0.0`. All three services `healthy`. "rapid-selector: database failing" has not fired | The `ss` and `ps` output, and the state of that rule | 0 |

D6 will not fire the alerts by itself. The budget rules need under 20% of a team's budget left (over $19.20 spent of `experiments`' $24), and the failure rule watches only the roles, while the drain test calls an experiment name. D8 tests the budget alerts on purpose. The failure-rate rule stays unproven until it fires for real.

## D. Level 3 (real money)

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| D1 | **Test B, the key limit.** With the inference key's limit still at $0.05: `./rapidselector.sh run-script scripts/drain-balance.sh --max-usd 0.10 --max-tokens 1024 --parallel 5` and type `drain` | Rounds of 5 calls with 200, then refusals from OpenRouter (402 or 403) with smaller and smaller calls, ending in `stopped: refused`. `stopped: error` or `stopped: in-flight` means the test did not finish, and `stopped: max-usd` or `stopped: max-calls` means the limit did not stop the calls: stop and tell Claude | The script's whole output, and the key's usage in OpenRouter's dashboard: how far past $0.05 did it go? | up to about $0.10 |
| D2 | Set the inference key's limit to **$35**, monthly | | The new limit | 0 |
| D3 | **Spend per model:** first `tests/check-prices.sh`: on any `FAIL` line, stop and tell Claude. Then `./rapidselector.sh run-script scripts/smoke-test.sh --all` | 11 `ok` lines, then 11 names with 200 and a cost above zero | The output | under $0.05 |
| D4 | **Hosts and cost:** in OpenRouter's activity log, open each call from D3 | For each call: the provider and quantisation of its pin (e.g. DeepInfra, bf16), and a cost equal to the one in D3's output | Any call with another host, or a cost that differs | 0 |
| D5 | **Zero data retention, negative.** Claude gives you a temporary entry pinned to an endpoint without zero data retention, to add to `gateway/config.yaml` without committing. `./rapidselector.sh restart gateway`, then call it once with the **master key** (the other keys may only use the 11 names, so the gateway would refuse them before anything is sent). Then `git checkout gateway/config.yaml` and `./rapidselector.sh restart gateway` again | The call is refused by **OpenRouter**, with a message about no endpoint matching the data policy or the provider list. A refusal from the gateway itself (401, "not allowed to access model") does not count | The status and the full message | 0 |
| D6 | **Test A, empty balance.** First `tests/check-prices.sh`: on any `FAIL` line, stop and tell Claude. Then `./rapidselector.sh run-script scripts/drain-balance.sh --max-usd <balance + 1> --max-calls 2000` and type `drain`. It may take a long time, and you can stop it with Ctrl-C | Rounds of 5 calls with 200 until the balance runs low, then refusals with smaller and smaller calls, ending in `stopped: refused`. Any other `stopped:` line means the test did not finish, usually with money left: tell Claude, and it can be run again | The script's whole output, and the balance in OpenRouter's dashboard afterwards: zero, or below zero, and by how much | the rest of the top-up, and up to about $0.25 below zero if OpenRouter's holds do not protect the balance |
| D7 | The regular top-up | The balance | Amount and balance | the top-up |
| D8 | **Budget alerts.** Read `experiments`' spend in the admin UI. `BUDGET_TEAM_EXPERIMENTS=<spend × 1.05> ./rapidselector.sh run-script scripts/setup-keys.sh`, then `./rapidselector.sh run-script scripts/smoke-test.sh` so the gateway updates its metric. Wait for the emails, up to 30 minutes. Then `./rapidselector.sh run-script scripts/setup-keys.sh` to restore the budget, and the smoke test once more so the metric follows | Emails from "rapid-selector: team budget below 20%" and "below 10%". The table from `setup-keys.sh` shows `experiments` at 24 again, and within about 20 minutes both rules have cleared | That both emails came, the restored budget, and that the rules cleared | under $0.01 |

## E. Backups and first real use

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| E1 | After the first nightly backup run, check `backup_last_status` for `rapidselector-postgres` and `rapidselector-chat` in Grafana or Prometheus | Both 1 | Both values and the file sizes, so `min_bytes` can be set. Then raise the backup count from 9 to 11, as `grafana/rapidselector-alerts.md` in `production` describes | 0 |
| E2 | **Restore rehearsal:** Claude gives you the commands to restore the newest dump into a separate Compose project on `sandbox` and call it with `KEY_NODE_RED` | The call is answered | The result | under $0.001 |
| E3 | **First real use:** a Node-RED flow with an HTTP request node that calls `classify` at `http://sandbox:4000/v1/chat/completions` with `KEY_NODE_RED` | An answer | That it works | under $0.001 |

When every step is done and recorded, phase 0 is verified. C5 runs on `sandbox`, which is the permanent host (`decisions.md`, 2026-11-06).
