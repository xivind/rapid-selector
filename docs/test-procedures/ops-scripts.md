# Scripts instead of tower: test procedure on `sandbox`

We go through this together, one step at a time: Claude says what to run or click, you say what you saw, and Claude records each result in `docs/decisions.md`. Do not run ahead. Part A removes tower everywhere; part B tries the new scripts on the real stack. Design: `docs/superpowers/specs/2026-11-08-scripts-instead-of-tower-design.md`.

**Start only when** `ops-scripts` is built, pushed and has passed its cloud Docker run.

**Cost ceiling:** under **$0.01**, all of it in B5's smoke test. **Stop rule:** if anything shows more spent than a step's stated cost, or a step's output differs from "You should see", stop and tell Claude before the next step.

**Where:** on `sandbox`, in `~/code/rapid-selector`, unless the step says otherwise. Never paste a secret value to Claude: names, lengths and statuses only.

## A. Cleanup: everything tower left behind

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| A1 | While the clone is still on `tower-part-1a`: `docker rm -f rapidselector-tower`, then `./rapidselector.sh ps` | `rapidselector-tower` printed once; then `chat`, `db` and `gateway` still running, no `tower` | The `ps` output | 0 |
| A2 | `git fetch`, then `git switch ops-scripts`, then `git log -1 --oneline` | `Switched to a new branch 'ops-scripts'`, and the commit Claude names | The `log` line | 0 |
| A3 | `scripts/cleanup-tower-secrets.sh` (on the host, not through `rapidselector.sh`). Then run it a second time | First `stored.` and 11 names with lengths: the 9 from phase 0 unchanged, `OPENROUTER_MANAGEMENT_KEY` 73 and `KEY_SCRIPTS` 51; no `TOWER_*`. The second run: `nothing to change.` and the same 11 | Both outputs (names and lengths only) | 0 |
| A4 | `grep -n '^TOWER_\|^OPENROUTER_' .env`. Delete every `TOWER_` line with `nano .env` (save: `Ctrl+O`, `Enter`, `Ctrl+X`), then run the `grep` again | First `TOWER_PORT=4020` (and any other `TOWER_` line) and the two `OPENROUTER_` settings; afterwards only `OPENROUTER_INFERENCE_KEY_NAME` and `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT=2027-11-07` | The second `grep` | 0 |
| A5 | `./rapidselector.sh up`, then `./rapidselector.sh ps` after a minute | No warning about an orphan container, nothing recreated or rebuilt; `chat`, `db` and `gateway` `healthy`, no `tower` | Both outputs | 0 |
| A6 | `./rapidselector.sh run-script scripts/setup-keys.sh`. Then `./rapidselector.sh run-script scripts/cleanup-tower-user.sh`, twice | The teams and keys as at D8, and a new row `scripts` with team `-`, budget `none`, `0` names; no `tower` row. Then `removed: 1 key(s) with alias tower` and `removed: user tower`; the second run `nothing to remove` | All three outputs | 0 |
| A7 | `docker ps -a --format '{{.Image}}' \| sort -u`, then `docker image ls` | No container uses `rapidselector-tower`, `python:3.14.7-alpine3.24` or `ghcr.io/astral-sh/uv:0.13.5`; those three images listed | Both outputs. Claude confirms what is safe to remove before the next row | 0 |
| A7b | `docker image rm rapidselector-tower:0.1.0 python:3.14.7-alpine3.24 ghcr.io/astral-sh/uv:0.13.5`, then `docker volume rm rapidselector_towerdata`, then `docker builder du` | `Untagged` and `Deleted` lines for each image; the volume's name; the build cache left. If the build cache is only tower's, Claude asks you to run `docker builder prune -f` (it removes all build cache on `sandbox`, which only makes the next build of any image slower) | The outputs | 0 |
| A8 | In OpenRouter's dashboard, Management API Keys: open `rapidselector-tower` and rename it `rapidselector-scripts`. Its value and expiry do not change | The key listed as `rapidselector-scripts`, expiry Nov 7, 2027 in its record | That the name changed | 0 |
| A9 | Extended mode only. Prometheus (in `production`), Status → Targets; Grafana, Alerting → Alert rules, group `LLM` | No target named `rapidselector-tower`; the gateway's 8 rules, nothing of tower's | What you see | 0 |
| A10 | Claude, on this machine with your go-ahead: in the `production` checkout, delete the local branch `rapidselector-tower` (never pushed), and search `main` for `tower` in rapid-selector's files | `Deleted branch rapidselector-tower`; the search finds nothing | Your go-ahead | 0 |

**Claude's, listed so you see them done** (after part B passes):

- **A11:** delete `tower-part-1a` on GitHub (`git push origin --delete tower-part-1a`; no pull request exists, no tag kept).
- **A12:** on this machine, remove the worktree `.worktrees/tower-part-1a` (with its ledger and `tower/.venv`) and the local branch, delete tower's mockups in `.superpowers/brainstorm/`, and update Claude's memory notes about tower.
- **A13:** search the repository for `tower`: only `docs/decisions.md`'s dated entries, the design, and other dated records may remain. Delete the one-off scripts `scripts/cleanup-tower-secrets.sh` and `scripts/cleanup-tower-user.sh` and their tests `tests/cleanup.bats`. Close finding 42 as moot. Rewrite `docs/test-procedures/phase-0-status.md`.

## B. The scripts on the real stack

| # | Do | You should see | Report back | Cost |
|---|---|---|---|---|
| B1 | `./rapidselector.sh run-script scripts/status.sh`, with OpenRouter's dashboard open beside it (Credits, and the key `rapidselector-gateway`) | Balance, the key's limit ($35), what is left, usage today, this week and this month, all matching the dashboard within a few cents; the budgets; `Expires 2027-11-07`; `No warnings.` (or warnings you can explain, such as a balance below $10) | The output, and any figure that does not match | 0 |
| B2 | `./rapidselector.sh run-script scripts/reconcile.sh --days 7`. If more than 7 days have passed since 2026-11-06, use a larger `--days` (up to 30) so the window still holds 11-05 and 11-06 | One line per day and model with a total per day; `openai/gpt-oss-120b` on 11-06 is one line, gateway `$0.0010` against OpenRouter `$0.0010` (tower showed it as two lines); `Nothing flagged.` | The output. A `!` line: stop | 0 |
| B3 | `scripts/check-prices.sh` | `rules ok: 11 entries`, then 11 `ok` lines | The output. A `FAIL` line: stop | 0 |
| B4 | `./rapidselector.sh restart gateway`, then `./rapidselector.sh ps` after a minute | `rules ok: 11 entries`, then Compose restarting `rapidselector-gateway`; `gateway` `healthy` again | Both outputs | 0 |
| B5 | `./rapidselector.sh run-script scripts/smoke-test.sh` | Four roles with `200` and a cost above zero, two `refused:` lines, `OK` | The output | under $0.01 |
| B6 | Extended mode. `systemctl list-units --type=service \| grep -i node`, then `systemctl cat <that unit> \| grep textfile` | A node exporter unit, running with `--collector.textfile.directory=/var/lib/node_exporter/textfile` | Both outputs | 0 |
| B6b | If you want the cron job now: `ls -ld /var/lib/node_exporter/textfile`, then `scripts/write-metrics.sh`, then `ls -l /var/lib/node_exporter/textfile` | Your user may write there; afterwards `rapidselector_status.prom` and `rapidselector_reconcile.prom`. Then the cron line from the README's "Optional: cost figures in Prometheus", with `crontab -e` | The outputs, and whether the cron line is in | 0 |

**When it passes:** Claude records each step in `docs/decisions.md`, does A11 to A13, and updates `docs/test-procedures/phase-0-status.md`. Next come Grafana's alerts and dashboard from a `production` session (plan Task 14, extended mode), and last the onboarding to LiteLLM and OpenRouter together (Task 15).
