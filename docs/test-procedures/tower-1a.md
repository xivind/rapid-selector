# Tower part 1a: test procedure

We go through this together: Claude walks you through each step, you say what you saw, and Claude records the results in `docs/decisions.md`. Do not run ahead: some steps spend real money, and a step whose result looks wrong is where we stop and look. Never paste a secret value to Claude: names, lengths and statuses only.

**Cost ceiling:** under **$0.05** in all. The smoke test (step D3) is under $0.01, and the probe in steps E2 and E3 spends a few millionths of a dollar a call. **Stop rule:** if OpenRouter's activity log shows more spent than the step's stated cost, stop and tell Claude before the next step.

**Where:** on `sandbox`, in the repository clone, on the branch Claude names (`git pull` first). Pages are opened in a browser on any computer on the home network. Commands are short on purpose: if one breaks when you paste it, tell Claude.

**Before you start:** phase 0 is done, the stack is running, and the manual ways to stop spending (disable the OpenRouter key, `docker stop rapidselector-gateway`) in the README still work without tower. This procedure never relies on tower alone.

## A. Secrets and keys

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| A1 | In OpenRouter's dashboard, create a **management key** with an expiry of **one year**. Keep it at hand: it is shown once. Write down the expiry date | The key, and its expiry date in the key list or in the creation dialog | The expiry date, and whether the dashboard shows it after creation | 0 |
| A2 | `scripts/add-tower-secrets.sh`. When it asks, paste the management key (nothing is shown) and press Enter | `stored.` and a list of names and lengths: the 9 old fields, then `TOWER_PASSWORD` 32, `TOWER_SESSION_SECRET` 64, `TOWER_GATEWAY_KEY` 51, `OPENROUTER_MANAGEMENT_KEY` about 70. Running it again changes nothing | The list of names and lengths | 0 |
| A3 | Only if A1 showed an expiry date and tower cannot read it (step C3 tells): `nano .env` and set `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT=2027-11-06` with your date. Skip it for now otherwise | | Whether you set it | 0 |
| A4 | `git pull`, then `./rapidselector.sh run-script scripts/setup-keys.sh` | A table with the same teams and keys as before, and a line showing tower's user and key created | The table | 0 |

## B. Start tower

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| B1 | `./rapidselector.sh up`. The first time it builds tower's image on the Pi, which takes a few minutes | The build output, then `rapidselector-tower` started. The other services are not recreated | Whether the build finished, and how long it took | 0 |
| B2 | `./rapidselector.sh ps` | Four containers, all `healthy` | The output | 0 |
| B3 | `ss -tln '( sport = :4020 )'` | The port listens on sandbox's LAN address only, never `0.0.0.0` | The output | 0 |
| B4 | `free -h`, to compare with phase 0's B5 | A little more memory in use | The output | 0 |

## C. Reading the pages

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| C1 | Open `http://sandbox:4020` and log in with `TOWER_PASSWORD`. To read it: `./rapidselector.sh run-script bash -c 'echo "$TOWER_PASSWORD"'` (never paste it to Claude) | The login page, then the Cost page. At the top the kill switch reads **ALL CLEAR**. A wrong password is refused | Whether login worked | 0 |
| C2 | **Cost against OpenRouter.** Open the Cost page and OpenRouter's dashboard side by side. Compare the balance, the inference key's limit and remaining limit, and the usage for the day, the week and the month | The same figures, within a few cents' delay. The month figure matches the key's monthly usage. Reconciliation (gateway against OpenRouter) is not flagged | The tower figures and OpenRouter's, side by side, and the reconciliation line | 0 |
| C3 | Open the **Setup** page and read the **Management key** section | Either the number of days left (about 365) or a warning that the expiry is unknown. Tower cannot yet read the date from OpenRouter's key list, so unknown is likely. If so, do A3 now, then `./rapidselector.sh up` and reload | Which of the two you saw, and the days left after A3 | 0 |
| C4 | Still on Setup: read **Models**, **Teams and keys** and **OpenRouter key** | The 11 names with their host, ZDR `yes`, fallbacks `off` and prices. The teams and keys with the budgets from the README. The inference key `rapidselector-gateway`, enabled, limit $35 | Anything that differs from the README or `gateway/config.yaml` | 0 |
| C5 | Open the **Usage** and **Log** pages | Usage per name and per key. The Log is empty or holds only what you have done in this procedure | That they open | 0 |
| C6 | `curl -s http://sandbox:4020/metrics \| grep -c '^rapidselector_'` and `curl -s http://sandbox:4020/health` | A number above 10, and an answer with status ok. No password is needed | Both results | 0 |

## D. Checks

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| D1 | On the Cost page, press **Check prices (free)** | A table with one row per name, all `ok`. A `FAIL` line means a price differs from OpenRouter's: stop and tell Claude | The table, or the FAIL lines | 0 |
| D2 | Press **Smoke test: roles**. Do not confirm yet | A list of the names to be called and a **worst case** figure in dollars. It is a ceiling, not an estimate | The worst-case figure | 0 |
| D3 | Press **Run smoke test** | `OK`, the four roles with HTTP 200 and a cost above zero, a total under $0.01. The CHECKS section says smoke test ok | The table and the total | under $0.01 |
| D4 | In OpenRouter's activity log, find the four calls from D3 | The same four hosts as in the gateway's config, and costs equal to tower's | Any call with another host or a different cost | 0 |

## E. Kill switch

The kill switch is the part of tower that stops money. Do these steps in order, and release each level before the next step. Keep OpenRouter's dashboard open in another tab: if tower fails to release something, you can re-enable the key there, and the README's manual ways still work.

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| E1 | **Level 1, with Node-RED and chat.** Press **STOP · level 1**, then **Confirm level 1**. Then: (a) send a message in chat at `http://sandbox:4010`; (b) make the Node-RED call from phase 0's E3; (c) `./rapidselector.sh run-script scripts/smoke-test.sh` | The kill switch reads **LEVEL 1** and says it blocked 2 or 3 keys. (a), (b) and (c) are all refused by the gateway, with no spend. Tower's own pages still work. The Cost page's smoke test button refuses with the reason. Then type `release` and press **Release level 1**: **ALL CLEAR**, and (a) works again | What each of (a), (b), (c) did, and the message each gave | under $0.001 |
| E2 | **Level 2, the real key.** Open a second terminal on `sandbox` and run `./rapidselector.sh run-script scripts/probe-key.sh`. It calls `classify` with the master key every 3 seconds and prints the time and status. With ALL CLEAR the lines show `200` (each call costs a few millionths of a dollar). In tower, press **STOP · level 2** and **Confirm level 2**, and note the time you pressed Confirm. Watch the probe, and stop it with Ctrl-C when it has shown refusals for a minute | The kill switch reads **LEVEL 2** and says the OpenRouter key is disabled. OpenRouter's dashboard shows the key disabled. The probe lines change from `200` to a refusal (401, 402 or 403) | **How many seconds after Confirm the first refusal came, and whether any `200` followed it.** The refusal's message, and in particular whether it came from OpenRouter or from the gateway. How long the lines kept showing `200` is the answer to "how fast does OpenRouter refuse a disabled key" (spec: not documented). If it took more than 30 seconds, say so before the next step | under $0.001 |
| E3 | **Release level 2, and measure the way back.** Run the probe again (second terminal). In tower, type `release` in the box and press **Release level 2** | The OpenRouter key is **enabled** again in the dashboard. Tower now shows **LEVEL 1** (still blocking keys; the master key is not one of them, so the probe is answered). If the probe is refused by the gateway itself at level 1, tell Claude: the measurement then needs another way. The probe lines go back to `200`, so note after how many seconds | The seconds until the first `200`. Whether OpenRouter's dashboard agrees with tower | under $0.001 |
| E4 | **Release level 1.** Type `release` and press **Release level 1**. Then the chat message and the Node-RED call again | **ALL CLEAR**. Chat and Node-RED answer. The Log page lists every engage and release with the time | That both work again, and the Log | under $0.001 |
| E5 | **Tower restores only what it engaged.** In the gateway's admin UI (`http://sandbox:4000/ui`) block the key `smoke-test` by hand. In tower press **STOP · level 1** and confirm, then release level 1. Look at the key in the admin UI. Then unblock `smoke-test` by hand | After release, `smoke-test` is **still blocked** and tower names it ("blocked outside tower"). It is not unblocked by tower | Whether it stayed blocked | 0 |
| E6 | **Engaged state survives a restart.** Press **STOP · level 1** and confirm. `./rapidselector.sh restart tower` and reload the page. Then release level 1 | After the restart the page still says **LEVEL 1**, with the same keys. Release returns it to ALL CLEAR | What the page said after the restart | 0 |
| E7 | **Tower down, manual stop still works.** `docker stop rapidselector-tower`. In OpenRouter's dashboard disable the inference key, run the probe (it should be refused), and enable the key again. `./rapidselector.sh up` | The manual way from the README works with tower stopped. Tower comes back and shows the right state: ALL CLEAR once the key is enabled again | That the probe was refused, and the state tower showed | 0 |

After E, the kill switch must read ALL CLEAR and the inference key must be **enabled** in OpenRouter's dashboard. Check both before going on.

## F. With a source missing

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| F1 | `docker stop rapidselector-gateway`, wait a minute, reload tower's Cost page, then `./rapidselector.sh up` | The page still renders within a few seconds. The parts that need the gateway say, in warning colours, that the gateway cannot be read. The OpenRouter figures still show. After `up` and a minute, everything is back | What the page showed while the gateway was down, and roughly how long it took to load | 0 |

## G. Backup and alerts (`production` repository)

The `production` changes are on the branch `rapidselector-tower` there, and are pushed and merged only with your permission.

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| G1 | On `sandbox`, pull the `production` changes where the backup export script is installed, and install the new one: `sudo install -m 755 ~/code/production/backup-orchestrator/remote/rapidselector-export.sh /usr/local/bin/` (the path to the clone may differ) | | That it is installed | 0 |
| G2 | On home-assistant: `sudo ssh -T -i /root/.ssh/backup-rapidselector rapidselector-backup@sandbox tower \| head -c 16; echo` | `SQLite format 3` | The output | 0 |
| G3 | Pull the `production` changes on home-assistant, then `sudo /home/pi/code/production/backup-orchestrator/backup-run.sh rapidselector-tower` | `ok` for the job, and a file under `rapidselector-tower/daily/` on the share | The `ok` line and the file size, so `min_bytes` can be set to about half of it in `jobs.conf` | 0 |
| G4 | After the first success, in Grafana or Prometheus: `backup_last_status{backup_job="rapidselector-tower"}` | 1. Then raise the backup count from 11 to 12 (the "Backup missing" rule and the two panels), as `grafana/rapidselector-tower-alerts.md` in `production` describes. Not before: it would fire "Backup missing" | The value, and that the count is 12 | 0 |
| G5 | Pull the `production` changes where Prometheus runs and restart Prometheus | Target `rapidselector-tower` is `up` in Prometheus | The target status | 0 |
| G6 | In a local Claude Code session in the `production` repository (with `GRAFANA_MCP_TOKEN` set), create the alert rules and panels from `grafana/rapidselector-tower-alerts.md` through the Grafana MCP | The eight rules in folder **Alerts**, group **LLM**, and the new panels | That they exist | 0 |
| G7 | **Fire one alert on purpose.** Engage level 1 in tower and keep it for 2 minutes. Look at the rule "kill switch engaged", then release | The rule fires and mails after a minute, and clears after the release | That the mail came and the rule cleared | 0 |

## When everything is done

Claude records in `docs/decisions.md`: the seconds from E2 and E3 (how fast OpenRouter refuses and accepts a key after it is disabled or enabled), what C3 showed about the management key's expiry, and the figures from C2. Until you have run these steps, tower part 1a is **not verified** on the real system.
