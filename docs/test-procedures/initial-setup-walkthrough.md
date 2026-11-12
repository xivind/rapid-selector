# Initial setup walkthrough

Run this once on a new host, alongside the README's "First setup", to prove that the limits, the alerts and the backups work before you rely on them (`CLAUDE.md`, principle 1: a limit counts as working only once it has been tested in practice). The README stays the only installation guide; this adds the checks. Claude can walk you through it one step at a time.

**Cost ceiling:** at most **$1 plus the smallest top-up**, which D6 spends on purpose. **Stop rule:** if OpenRouter's activity log shows more spent than a step's stated cost, or a step's output differs from "You should see", stop before the next step.

**Results:** compare each with `docs/decisions.md`, "Tested in practice". Add a line there only when a result is new or different.

Commands run on the host, in the clone. Expected values come from your own `config/gateway.yaml` (the names) and `config/home.env` (the budgets).

## A. OpenRouter

| # | Do | You should see | Cost |
|---|---|---|---|
| A1 | README, "1. Prepare OpenRouter", items 1 and 2. Also: under zero data retention choose `ZDR only` (not `Allow Safety Retention`) wherever it is offered, and limit Allowed Providers to the hosts your `config/gateway.yaml` pins | The settings saved | 0 |
| A2 | README item 3, but give the gateway's key a limit of **$0.05** for now (D1 tests it) | The key, shown once | 0 |
| A3 | README item 5: buy the **smallest top-up** offered | The balance | the top-up |

## B. Install and check the host (no money, apart from B6)

| # | Do | You should see | Cost |
|---|---|---|---|
| B1 | README, "2. Get the code and create the settings file" and "3. Create the secrets" | The README's checks pass | 0 |
| B1a | **Before anything is started:** the level 1 tests use the same container names as the real stack, so they run only now. Install `jq`; without Node, `git clone --depth 1 --branch v1.11.0 https://github.com/bats-core/bats-core.git ~/bats-core`. Then `~/bats-core/bin/bats tests/*.bats 2>&1 \| tee ~/level1.log`, and `grep -c '^ok' ~/level1.log; grep '^not ok' ~/level1.log` | A count of passed tests and no `not ok` lines (it takes a while on a Pi, plus about 2 GB of images) | 0 |
| B2 | `free -h`, then README "4. Start everything" | All three `healthy` | 0 |
| B3 | README "5. Create the teams and keys in the gateway" | The teams' and keys' budgets from `config/home.env`, and as many names as `config/gateway.yaml` holds | 0 |
| B4 | README "6. Create the Open WebUI admin account" | Every name in the model list | 0 |
| B5 | `free -h` again, and `ps -eo rss,comm --sort=-rss \| head -15` (`docker stats` shows no memory where the kernel's memory control is off) | The stack fits, with room to spare (about 0.8 GiB more than at B2 was seen with the slim Open WebUI image) | 0 |
| B6 | README "7. Run the smoke test" | Every role with `200` and a cost above zero, two `refused:` lines, `OK` | under $0.01 |

## C. The host on the network, and integrations

| # | Do | You should see | Cost |
|---|---|---|---|
| C1 | **Optional, with Prometheus:** README, "Optional: cost figures in Prometheus", and a scrape target for the gateway's `/metrics/` | The target `up` | 0 |
| C2 | **Optional, with alerts:** create your rules on the gateway's metrics (budgets, failures, the gateway down) | The rules, not firing | 0 |
| C3 | **Optional, with backup jobs:** set them up for Postgres and Open WebUI's data, leaving out `/app/backend/data/cache` (`docs/decisions.md`, 2026-11-06). Without them, README, "Backups" | — | 0 |
| C4 | From another machine on the LAN, as a client would (for example inside Node-RED's container): `curl -s -o /dev/null -w '%{http_code}\n' http://<host>:<GATEWAY_PORT>/metrics/` | `200` | 0 |
| C5 | **Reboot check:** `sudo reboot`. Ten minutes after the host is back: `ss -tln '( sport = :<GATEWAY_PORT> or sport = :<CHAT_PORT> )'` and `./rapidselector.sh ps` | Both ports on the LAN address only, never `0.0.0.0` or `[::]`, and all three `healthy`, started without `up` | 0 |

## D. The limits, with real money

| # | Do | You should see | Cost |
|---|---|---|---|
| D1 | **The key limit**, still at $0.05: `./rapidselector.sh run-script tests/drain-balance.sh --max-usd 0.10 --max-tokens 1024 --parallel 5` and type `drain` | Rounds of 5 calls with 200, then either refusals and `stopped: refused`, or `stopped: max-usd` with spend past $0.05 (as seen, since OpenRouter counts spend late). Then one smoke test: refused with 403 `openrouter_key_limit`. Read the key's usage in OpenRouter: how far past $0.05 it went | up to $0.10 |
| D2 | Raise the key's limit to the one you want, a little above the global budget (README item 3) | The new limit | 0 |
| D3 | **Spend per name:** `scripts/check-prices.sh` (on any `FAIL` line, stop), then `./rapidselector.sh run-script scripts/smoke-test.sh --all` | One `ok` per name; then every name with 200 and a cost above zero | under $0.05 |
| D4 | **Hosts and cost:** on OpenRouter's Logs page, open each call from D3 | Each call served by its pin's provider, at the cost D3 printed | 0 |
| D5 | **A host outside the account's list:** see below | 404 from OpenRouter, "No allowed providers…", nothing charged | 0 |
| D6 | **The balance:** `scripts/check-prices.sh`, then `./rapidselector.sh run-script tests/drain-balance.sh --max-usd <balance + 1> --max-calls 2000` and type `drain`. It may take long; OpenRouter refuses more and more calls as the balance runs out. The drain calls `qwen3.8-2.4t-a95b@siliconflow`, which your config must hold, through a temporary key in team `experiments`: that team's budget, the global budget and the key limit must all be above the balance, or it ends on one of them (`stopped: gateway-budget`) | The balance a little below zero (−$0.19 seen). `stopped: error` or `stopped: in-flight` with money left (a new account's rate limit, for example) means it did not finish: run it again | the top-up |
| D7 | Top up as you normally will | The balance, after the overshoot is covered | the top-up |
| D8 | **Optional, the budget alerts:** read team `experiments`' spend in LiteLLM's admin UI. `BUDGET_TEAM_EXPERIMENTS=<spend × 1.05> ./rapidselector.sh run-script scripts/setup-keys.sh`, then a smoke test, so the gateway updates its figures. Afterwards run `setup-keys.sh` again without the setting | Your budget rules fire, and **their emails arrive** (test the email, not only the firing) | under $0.01 |

**D5, step by step.** Add a temporary entry to `config/gateway.yaml`, named `zdr-negative-test`, in the form of the others, pinned to an endpoint at a provider **outside** your allowed list (OpenRouter's page for a model lists its providers), with `max_tokens: 16`. The rules check refuses such an entry, which is its job, so `./rapidselector.sh restart gateway` will not load it: restart with `docker restart rapidselector-gateway` this once, wait until `./rapidselector.sh ps` shows it `healthy`, then call it with the master key (the last line printed is the HTTP status):

```bash
./rapidselector.sh run-script bash -c 'printf "Authorization: Bearer %s\n" "$LITELLM_MASTER_KEY" | curl -s -H @- -H "Content-Type: application/json" -w "\n%{http_code}\n" -d "{\"model\": \"zdr-negative-test\", \"max_tokens\": 16, \"messages\": [{\"role\": \"user\", \"content\": \"hi\"}]}" "http://$RAPIDSELECTOR_LAN_ADDRESS:$GATEWAY_PORT/v1/chat/completions"' | sed -E "s/sk-[A-Za-z0-9_-]+/sk-REDACTED/g"
```

Then delete the entry and run `./rapidselector.sh restart gateway`, which must print `rules ok`.

## E. Backups

| # | Do | You should see | Cost |
|---|---|---|---|
| E1 | After the first nightly backup (or the README's commands), list the files | A Postgres dump and Open WebUI's data, neither empty; the chat backup a few MB, not GB | 0 |
| E2 | **Restore:** not yet written or tested (`docs/roadmap.md`, parked options). Keep the secrets with the backups: without `LITELLM_SALT_KEY` a restored database cannot read what it stored | — | — |
