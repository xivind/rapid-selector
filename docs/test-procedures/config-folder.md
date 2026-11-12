# The `config/` folder: moving `sandbox` over

We go through this together, one step at a time: Claude says what to run or click, you say what you saw, and Claude records each result in `docs/decisions.md`. Do not run ahead. Design: `docs/superpowers/specs/2026-11-11-config-folder-design.md`; plan: `docs/superpowers/plans/2026-11-12-config-folder.md`.

**Start only when** the branch `config-folder` has passed its cloud Docker run and is merged into `main`, and Claude has written and checked your own `config/gateway.yaml` and `config/home.env` on this machine (the plan's Task 8: `rules ok: 12 entries` and 12 `ok` prices).

**The order matters.** `git pull` on `sandbox` deletes the tracked `gateway/config.yaml`, which the running gateway has mounted, so `sandbox`'s `config/` must hold both files before the pull (C1). After the pull, the containers are recreated with `up`, not `restart`. A restart keeps the old mount, and Docker would then create a *directory* named `gateway/config.yaml` and the gateway would not start. So **do not run `restart gateway` between C3 and C4, and do C4 right after C3**: a reboot in between restarts the containers the same way.

**Cost ceiling:** under **$0.01**, all of it in C7 and C8. **Stop rule:** if anything shows more spent than a step's stated cost, or a step's output differs from "You should see", stop and tell Claude before the next step.

**Where:** each step says: **here** is this Chromebook, in `~/code/rapid-selector` on `main`; **`sandbox`** is `~/code/rapid-selector` there. Never paste a secret value to Claude: names and statuses only.

| # | Where | Do | You should see | Report back | Cost |
|---|---|---|---|---|---|
| C1 | here | `git pull`, then `scripts/copy-config.sh to pi@sandbox`, and type `sandbox`'s SSH password when `ssh` asks | `rules ok: 12 entries`, then `copied gateway.yaml and home.env to pi@sandbox:code/rapid-selector/config`, and the next steps (not yet: Claude gives them below) | The output | 0 |
| C2 | `sandbox` | `ls config`, then `git status --short` | `gateway.yaml` and `home.env`; then `?? config/` (git does not ignore it until the pull) | Both outputs | 0 |
| C3 | `sandbox` | `git pull`, then `scripts/check-prices.sh --rules-only` | The pull lists `gateway/config.yaml` deleted and `config/`'s examples and `scripts/copy-config.sh` added; then `rules ok: 12 entries` | Both outputs. A `FAIL` line: stop | 0 |
| C4 | `sandbox` | `./rapidselector.sh up`, then `./rapidselector.sh ps` after two minutes | Compose recreating `rapidselector-gateway` (its mount changed) and `rapidselector-chat` (its setting changed); `db` untouched. Then all three `healthy` | Both outputs | 0 |
| C5 | `sandbox` | `docker inspect rapidselector-gateway \| grep config`, then `docker inspect rapidselector-chat \| grep TASK_MODEL` | A mount from `.../rapid-selector/config/gateway.yaml` to `/app/config.yaml`; then `TASK_MODEL_EXTERNAL=chat-tasks` | Both outputs | 0 |
| C6 | `sandbox` | `./rapidselector.sh run-script scripts/setup-keys.sh` | `team:permanent` with budget 8 and **5** names, `team:experiments` 24 and **12**; `node-red` 4 and RPM 30, `smoke-test` 1, `chat` and `scripts` as before | The output | 0 |
| C7 | `sandbox` | `./rapidselector.sh run-script scripts/status.sh`, then, after Claude has confirmed the cost with you, `./rapidselector.sh run-script scripts/smoke-test.sh` | `status.sh` as before, with the same budgets. Five roles, `chat-tasks` among them, each with `200` and a cost above zero; two `refused:` lines; `OK` | Both outputs | under $0.01 |
| C8 | browser | In Open WebUI (`http://<host>:4010`), start a new chat with any name and send one short message | The chat gets a title in the sidebar after the answer | Whether a title appeared | a fraction of a cent |

**After C8:** Claude records the results, changes the "Config changes" line in `docs/test-procedures/phase-0-status.md`'s "Things to remember" to `config/` and `copy-config.sh`, and sets "Next" to the docs cleanup (the spec's "Next projects").
