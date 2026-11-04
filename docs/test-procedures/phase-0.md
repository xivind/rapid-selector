# Phase 0: test procedure for levels 2 and 3

We go through this together: Claude walks you through each step, you say what you saw, and Claude records the results in `docs/decisions.md`. Do not run ahead: some steps spend real money, and a step whose result looks wrong is where we stop and look.

**Cost ceiling:** at most **$1 plus the smallest top-up**. The smallest top-up is spent on purpose in step D5. **Stop rule:** if OpenRouter's activity log shows more spent than the step's stated cost, stop and tell Claude before the next step.

**Where:** on `sandbox`, in the repository clone. Commands are run in that folder.

## A. OpenRouter preparation (in OpenRouter's dashboard)

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| A1 | Settings: turn auto top-up **off**. Privacy: prompt logging and every opt-in to data collection **off**. Zero data retention **on** for the account, if offered | The settings saved | Which of these you found, and their wording | 0 |
| A2 | Keys: create the gateway's inference key, named e.g. `rapidselector-gateway`, with a credit limit of **$0.05**, reset **monthly** | The key, shown once | That it exists, its limit and reset. Put the key in the secrets as `RAPIDSELECTOR_OPENROUTER_KEY` | 0 |
| A3 | Credits: buy the **smallest top-up** offered | The balance | The amount paid, the 5.5% fee, and the balance | the top-up |

## B. Level 2 on `sandbox` (little or no money)

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| B1 | Clone the repository, `cp .env.example .env`, fill in the settings (`RAPIDSELECTOR_LAN_ADDRESS` = sandbox's address, `SECRETS_SOURCE=secrets-service`, the token file). Generate the secrets and store them as the secret `rapidselector` in secrets-service | | That the secret exists with all 9 fields (names only, never values) | 0 |
| B2 | `./rapidselector.sh up -d`, then `./rapidselector.sh ps` after a few minutes | `rapidselector-db`, `rapidselector-gateway` and `rapidselector-chat`, all `healthy` | The `ps` output | 0 |
| B3 | `./rapidselector.sh run-script scripts/setup-keys.sh` | A table with 2 teams and 3 keys: `permanent` 8, `experiments` 24, `node-red` 4, `chat` team, `smoke-test` 1 | The table | 0 |
| B4 | Open `http://sandbox:4010`, create the admin account | Open WebUI, with the 11 names in the model list | That it worked and the names are there | 0 |
| B5 | `docker stats --no-stream` | Memory per container | The output. Claude sets the memory limits from it in a commit | 0 |
| B6 | `./rapidselector.sh run-script scripts/smoke-test.sh` | Four roles with status 200 and a cost above zero, two `refused:` lines, `OK` | The output | under $0.01 |

## C. `production` repository (warnings and backups before money is spent)

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| C1 | Merge the `production` branch with the rapid-selector changes; restart Prometheus | Target `rapidselector-gateway` is `up` in Prometheus | Target status | 0 |
| C2 | In a local Claude Code session in the `production` repository (with `GRAFANA_MCP_TOKEN` set), create the alert rules from `grafana/rapidselector-alerts.md` through the Grafana MCP | The rules in folder **Alerts**, group **rapid-selector** | That they exist | 0 |
| C3 | Install the forced-command SSH key for the backup jobs on `sandbox`, as described in `backup-orchestrator/README.md` | | That it is installed | 0 |
| C4 | Add `--add-host="llm:<sandbox's address>"` to Node-RED (already in the branch), restart Node-RED. Create the alias `llm` → `sandbox` on the router | `ping llm` from a computer answers from sandbox's address | The ping result | 0 |

The budget alerts are expected to fire during D5. That is part of the test.

## D. Level 3 (real money)

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| D1 | **Test B, the key limit.** With the inference key's limit still at $0.05: `./rapidselector.sh run-script scripts/drain-balance.sh --max-usd 0.10` and type `drain` | A few calls with 200, then refusals from OpenRouter (402) passed on by the gateway, a burst of 5 refused calls, `stopped: refused` | The script's summary, and the key's usage in OpenRouter's dashboard: how far past $0.05 did it go? | up to about $0.10 |
| D2 | Set the inference key's limit to **$34**, monthly | | The new limit | 0 |
| D3 | **Spend per model:** `./rapidselector.sh run-script scripts/smoke-test.sh --all` | 11 names with 200 and a cost above zero | The output | under $0.05 |
| D4 | **Hosts and cost:** in OpenRouter's activity log, open each call from D3 | For each call: the provider and quantisation of its pin (e.g. DeepInfra, bf16), and a cost equal to the one in D3's output | Any call with another host, or a cost that differs | 0 |
| D5 | **Zero data retention, negative.** Claude gives you a temporary entry pinned to an endpoint without zero data retention, to add to `gateway/config.yaml` without committing. `./rapidselector.sh up -d`, call it once with the smoke-test key, then `git checkout gateway/config.yaml` and `./rapidselector.sh up -d` again | The call is refused by OpenRouter (no endpoint matches) | The status and message | 0 |
| D6 | **Test A, empty balance.** `./rapidselector.sh run-script scripts/drain-balance.sh --max-usd <balance + 1>` and type `drain` | Calls with 200 until the balance runs out, then refusals, a burst of 5, `stopped: refused` | The summary, and the balance in OpenRouter's dashboard afterwards: zero, or below zero, and by how much | the rest of the top-up |
| D7 | The regular top-up | The balance | Amount and balance | the top-up |

## E. Backups and first real use

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| E1 | After the first nightly backup run, check `backup_last_status` for `rapidselector-postgres` and `rapidselector-chat` in Grafana or Prometheus | Both 1 | Both values and the file sizes, so `min_bytes` can be set | 0 |
| E2 | **Restore rehearsal:** Claude gives you the commands to restore the newest dump into a separate Compose project on `sandbox` and call it with `KEY_NODE_RED` | The call is answered | The result | under $0.001 |
| E3 | **First real use:** a Node-RED flow with an HTTP request node that calls `classify` at `http://llm:4000/v1/chat/completions` with `KEY_NODE_RED` | An answer | That it works | under $0.001 |

When every step is done and recorded, phase 0 is verified.
