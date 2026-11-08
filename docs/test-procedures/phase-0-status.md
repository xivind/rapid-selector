# Phase 0: where the walkthrough stands

A handoff between sessions, written 2026-11-04 and last updated on 2026-11-08. Update "Next step" and the state tables as steps finish, and delete this file when phase 0 is verified. Results themselves go in `docs/decisions.md`; this file only says where we are.

## Where we are (2026-11-08)

- **NOW: the owner's procedure `docs/test-procedures/ops-scripts.md` on `sandbox`, at step A9** (extended mode: Prometheus Status → Targets, no `rapidselector-tower`; Grafana Alert rules, group `LLM`, the gateway's 8 rules and nothing of tower's). A9 was handed to the owner on 2026-11-08: ask what they saw before going on. A1–A8 are done (`decisions.md`; the clone is on `ops-scripts` at `26d5b38`; the secret `rapidselector` has 11 fields, `KEY_SCRIPTS` added, tower's three gone; `TOWER_PORT` gone from `.env`; `up` recreated nothing; the gateway key `scripts` created, tower's key and user removed; A7 found tower's base images only in the build cache, and `python:3.15.2-alpine3.24` is level 1's, kept; A7b removed tower's image and volume, and the unused full `open-webui:v0.13.0` by the owner's choice, and the whole build cache was pruned). Walk the procedure one step at a time, as below ("How we work through the procedure"); record each result in `docs/decisions.md` on `phase-0-walkthrough`, commit and push.
- **Tower is dropped** (owner, 2026-11-07/08, `docs/decisions.md`). It is replaced by operator scripts on branch **`ops-scripts`** (pushed, `26d5b38`): design `docs/superpowers/specs/2026-11-08-scripts-instead-of-tower-design.md`, plan `docs/superpowers/plans/2026-11-08-scripts-instead-of-tower.md` (15 tasks). Tasks 1–12 are done: built, reviewed by one fresh reviewer (every finding fixed, test first, the minors too by the owner's choice), and the cloud Docker run passed (19 files, 199 tests). The record is the 2026-11-08 entries in `docs/decisions.md`. The two tower paragraphs below describe what tower left on `sandbox`, in `production` and on this machine until the procedure's part A removes it.
- **Decided on 2026-11-08, during the build** (`docs/decisions.md`): **the management key is optional** (without it everything runs except `status.sh` and `reconcile.sh`, which exit 3; what is lost is in `scripts/README.md`, "Without the management key"); and **LiteLLM stays as the gateway**, for six reasons recorded there, not to be reopened without new facts.
- **Phase 0:** A1–A3, B1a, B1–B6, C1–C5, D1–D8 and E1 are done and recorded in `docs/decisions.md`. **rapid-selector stays on `sandbox`** (owner). E2 moves to after tower part 1b. E3 (first real use from Node-RED) is open.
- **D6:** the balance is not a hard stop: it went to −$0.19 across two drain runs; `CLAUDE.md` principle 1 now says "plus a small overshoot". On 2026-11-07 a line under the three layers says "hard" means enforced by OpenRouter, not exact to the cent (`docs/decisions.md`).
- **D7:** $35 topped up; balance $34.81.
- **D8 done:** both budget rules fired, emailed (after Mailgun was fixed and the rules paused and resumed) and cleared at 22:24. `experiments` is back at $24.
- **Tower part 1a is built** on branch **`tower-part-1a`** (pushed; worktree `.worktrees/tower-part-1a` on this machine), subagent-driven: all 13 tasks reviewed, the final whole-branch review's fixes done and re-reviewed. 160 unit tests pass (`cd tower && uv run pytest`), and the third Docker run passed the whole level 1 suite (141 tests) at `5877b72` with no changes. The ledger is `.worktrees/tower-part-1a/.superpowers/sdd/2026-11-06-tower-part-1a/progress.md` (not in git). In `production`, branch **`rapidselector-tower`** (local only, not pushed) holds tower's backup job, Prometheus target and alert note, with a summary and description per rule (5 commits, 55b3781..8e36599; the checkout itself is back on `main`): merge it only when tower runs on `sandbox`, since its `jobs.conf` line fails the nightly run until the export word is installed there.
- **Tower's look was revised on 2026-11-07** and the owner signed it off (`docs/decisions.md`): status panel, lights and badges, comparisons and ◆ on Cost and Usage, Setup in tabs. Built on `tower-part-1a` (`5f4f393..eece57e`), 203 unit tests pass, and the cloud Docker run at `eece57e` passed (203 unit, 141 level 1); the plan and its workspace are closed. Afterwards, by the owner's look (`docs/decisions.md`): lights differ in shape (`fee4518`), Cost bars show share of spend, a reconciliation note and a legend on Setup (`fb152b8`); 208 unit tests, CSS and templates only. Then a reason line inside a Setup tab when its light is yellow or red (`672a24e`), the open tab's status line removed (`9ef162b`), and the reason line starting with a capital (`791b2b9`, the branch's head). Design `docs/superpowers/specs/2026-11-07-tower-look-revision-design.md`, plan `docs/superpowers/plans/2026-11-07-tower-look-revision.md` (done). To look at tower without Docker: `cd .worktrees/tower-part-1a/tower && uv run python tests/preview.py`, then `http://localhost:8765`, password `look`.
- **The real stack runs on `sandbox`.** Level 1 must not be run there. **Do not regenerate the secret `rapidselector`:** `LITELLM_SALT_KEY` must not change.

## Next, in order (the owner picks)

1. **Finish the plan `docs/superpowers/plans/2026-11-08-scripts-instead-of-tower.md`** (executed natively with `superpowers:executing-plans`; its ledger is `.worktrees/ops-scripts/.superpowers/sdd/2026-11-08-scripts-instead-of-tower/progress.md`, not in git, worktree `.worktrees/ops-scripts` on branch `ops-scripts`):
   - **Task 13, step 3, now:** the owner's procedure `docs/test-procedures/ops-scripts.md`, from A9 (see "Where we are"). Part A is the cleanup (A1–A10 by the owner, A10 by Claude on this machine with the owner's go-ahead); part B tries the scripts on the real stack (B1–B6c). Cost ceiling: under $0.01, all in B5's smoke test. After part B passes, Claude does A11–A13: delete `tower-part-1a` on GitHub; remove the worktree `.worktrees/tower-part-1a` and its local branch, tower's mockups in `.superpowers/brainstorm/`, and update Claude's memory notes about tower; the repository search for `tower`, deleting the one-off `scripts/cleanup-tower-secrets.sh`, `scripts/cleanup-tower-user.sh` and `tests/cleanup.bats` (on `ops-scripts`), closing finding 42 as moot, and rewriting this file.
   - **Task 14:** Grafana's four new alerts and the LLM dashboard, from a local Claude Code session in the `production` repository through its Grafana MCP, after B6 (the cron job writing both `.prom` files on `sandbox`). Pushing to `production`'s `main` needs the owner's permission each time.
   - **Task 15, last:** `docs/onboarding.md`, a guided tour of LiteLLM's admin UI and OpenRouter's dashboard, walked through together in the owner's browser by the owner (no subagent uses it).
   - **When the plan is done:** give the owner every `Ruling:` line from the ledger (the executor's decisions; the important ones were already shown during the build and the reviewer found them sound), then delete the ledger's directory, and use `superpowers:finishing-a-development-branch`.
2. **Merging:** `phase-0-walkthrough` into `main`, then `ops-scripts`, when the owner says; open the PRs then. `tower-part-1a` is never merged: it is deleted in the cleanup, with no tag. `sandbox` moved from `tower-part-1a` to `ops-scripts` at the procedure's step A2 (2026-11-08).
3. **After the merge:** the README dry run, and two-factor authentication on the OpenRouter account (both in `docs/roadmap.md`, phase 1).
4. **Benchmarking:** Open WebUI's arena and promptfoo, a brainstorm of its own after the plan (`docs/roadmap.md`). Tower part 1b is dropped. E2 (restore) is now independent of tower: Claude writes the restore commands when the owner picks it up.

## Things to remember

- **D1:** the key limit stops calls only after their spend is counted (86% past at D1); accepted by the owner. The gateway's budgets stay below the key limit; the fast stop is disabling the inference key in OpenRouter's dashboard (README, "Stopping all spending").
- **D5:** the account's allowed-provider list refused a non-ZDR host; the data policy on its own cannot be tested at the four allowed hosts, as none has an ordinary endpoint without zero data retention.
- **Config changes:** the gateway reads `gateway/config.yaml` from a mounted file, so after changing it run `./rapidselector.sh restart gateway`; `up` does not reload it.
- **`tests/resilience.bats`** ran in the cloud Docker run of 2026-11-08 (all 19 files passed).
- **`./rapidselector.sh restart gateway` now runs the rules check first** (on `ops-scripts`) and refuses with exit 5 if `gateway/config.yaml` breaks a rule.
- **jq versions:** this machine has jq 1.6, the cloud sandbox 1.7. Tests compare numbers as values, not as printed text, because the two print them differently.
- **The scripts' gateway key** (`KEY_SCRIPTS`, user `scripts`) uses role `proxy_admin_viewer` with three read routes, confirmed at level 1 (`provider-facts.md`).
- **Findings 38 and 39** (Hugging Face fetch, LiteLLM's own retries) are new and open in `docs/decisions.md`.
- **Tower 1a facts found** (history; tower part 1b is dropped): usage per name from `/user/daily/activity`; tower's own `proxy_admin` key with `allowed_routes` works (question 17); OpenRouter's key list needs `include_disabled=true`; level 1 does not block LiteLLM's master key or the admin UI's own session key (owner accepted). **For 1b, to try first:** database models resolve `os.environ/RAPIDSELECTOR_OPENROUTER_KEY` and accept the pin, prices and `max_tokens` (if not, stop and ask the owner), and that the `/openrouter` pass-through stays refused.
- **Mockups** from the design talks are in `.superpowers/brainstorm/` (not committed); the 2026-11-07 ones, versions 2 to 4 of tower's look, are in `.superpowers/brainstorm/4355-1794004845/content/`. The visual companion is stopped.

## How we work through the procedure

These are the owner's instructions for this walkthrough, on top of `CLAUDE.md`:

- The procedure (now `docs/test-procedures/ops-scripts.md`; before it, `phase-0.md`), one step at a time: what to run or click, what they should see, what it costs. **Wait for their report before the next step.** Record every result in `docs/decisions.md`, and commit and push it.
- **Stop and ask before anything that spends money beyond the procedure's stated cost.** Phase 0's ceiling was $6 of credit; the ops-scripts procedure's is under $0.01 (B5's smoke test).
- **The owner never pastes a secret value to Claude.** Names and statuses only.
- The owner is new to Compose. Plain language, complete commands, and say what each output should look like.
- The owner welcomes pushback and pushes back too: ask whether something is needed before proposing a change to a host. Example: the memory cgroup boot setting, proposed and then rightly dropped.
- Code changes use the superpowers skills and tests first.
- **Pasting is fragile on the owner's terminal:** a very long line broke (`subsh>`), a heredoc waited (`heredoc>`) and an indented Python block failed. Keep commands to short lines, never ask for a heredoc or indented code to be pasted, and put anything longer in a committed script the owner pulls. Run a silent `read -rs` line on its own.
- Every secret goes through `./rapidselector.sh run-script bash -c '…'` with the header on stdin (`curl -H @-`), and output that could hold a key goes through `sed -E "s/sk-[A-Za-z0-9_-]+/sk-REDACTED/g"`.

## State of things

### OpenRouter

| What | State |
|---|---|
| Balance | About $4.91: $0.00000978 spent at B6 and $0.0932 at D1. $7.25 paid |
| Inference key | `rapidselector-gateway`: limit $35 since D2, monthly reset. The value is in secrets-service, as `RAPIDSELECTOR_OPENROUTER_KEY` |
| Management key | `rapidselector-tower` (renamed `rapidselector-scripts` at procedure step A8, done 2026-11-08), created 2026-11-07, expires **2027-11-07** 09:41 UTC (set in `sandbox`'s `.env` as `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT`, since the API does not give it). The value is in secrets-service, as `OPENROUTER_MANAGEMENT_KEY` |
| Auto top-up | Off, and no card on file (Google Pay through Stripe) |
| Zero data retention | All 5 toggles on, `ZDR only` under "All other models" and "Google" |
| Data training and the 1% discount | All off |
| Allowed providers | Cloudflare, CoreWeave, DeepInfra, SiliconFlow |

### `sandbox`

- Clone at `/home/pi/code/rapid-selector`, on **`ops-scripts`** (`26d5b38`) since step A2 (2026-11-08). Tower's container was removed at A1 (2026-11-08); its image `rapidselector-tower:0.1.0`, volume `rapidselector_towerdata` and base images stay until A7; `TOWER_PORT` left `.env` at A4; tower's three fields left the secret `rapidselector` at A3, where `KEY_SCRIPTS` was added. `.env` is filled in, and the secrets-service token is in `~/.config/rapidselector/secrets-service.token`.
- `jq` installed. Docker images downloaded (about 1.9 GB). `~/bats-core` holds bats 1.11.0, because `sandbox` has no Node, so `tests/run.sh` (which uses `npx`) does not work there. Use `~/bats-core/bin/bats tests/*.bats 2>&1 | tee ~/level1.log`.
- The real stack started at B2. `/boot/firmware/cmdline.txt` was not changed: the kernel's memory control stays off by the owner's decision.
- All 103 level 1 tests have passed there, across two runs (`docs/decisions.md`). Level 1 cannot run beside the real stack, because the container names clash.

### Repositories

- **`rapid-selector`:** PR #2 is merged to `main`. Branch **`phase-0-walkthrough`** is pushed, with no PR yet. It holds the records from A1 on, the Safety Retention check, the always-detached `up`, the removal of the memory limits, the README's setup, the `llm` alias dropped, and the 2026-11-08 records (the build, the review, the cloud run, the two decisions, procedure A1). This machine's checkout is on that branch. Branch **`ops-scripts`** (from `phase-0-walkthrough`, pushed at `26d5b38`) holds the scripts; its worktree is `.worktrees/ops-scripts`. **`tower-part-1a`** (pushed) and its worktree `.worktrees/tower-part-1a` stay until A11 and A12.
- **`production`:** the rapid-selector changes (#181) and the alert note (#183) are merged. On 2026-11-05 Claude pushed two small commits straight to `main`, with the owner's permission: the alert group named `LLM`, and the `llm` line removed from `nodered/create-container-nodered.sh`. This machine's checkout (`~/code/production`) is on `main`, up to date, with graphify files modified by its hook, not by us. Its local branches `rapidselector-tower` (deleted at A10) and `rapidselector-alert-note` are not pushed. `home-assistant` and `messagebroker` pulled `main` during C1 and C4. On 2026-11-06, after D8, Claude pushed `dec5f60` to `main` with the owner's permission: a summary and description for each LLM rule in `grafana/rapidselector-alerts.md` (then `f3c5d72`, full rule names), applied to the 8 rules by a `production` session through the Grafana MCP, nothing else changed.

## To do before particular steps

- **E2:** was moved to after tower part 1b (owner, 2026-11-06); 1b is dropped, so E2 waits for the owner to pick it up. Claude writes the restore commands then. The backup has no `cache/`, and the slim image needs none.

## Deferred, for the owner to decide

Findings 20–25, 30, 32–36 and 38–42 in `docs/decisions.md`. None blocks the procedure. If finding 33's timing checks fail on the Pi in a later run, widen them.

## For developers on this machine

This Chromebook has no Docker, so `tests/run.sh` does not work here. The previous session ran `tests/drain.bats` and the upstream tests in `tests/fakes.bats` with real LiteLLM v1.106.6 and real Postgres outside Docker. That setup was in a scratchpad that is gone. To rebuild it, outside the repository:

- `uv venv` with Python 3.11, then install `litellm[proxy]==1.106.6`, `prisma`, `pgserver` and `prometheus_client`. Run `prisma generate --schema=<venv>/lib/python3.11/site-packages/litellm/proxy/schema.prisma`.
- Start Postgres with `pgserver.get_server(path, cleanup_mode=None)`. Its address needs a host for Prisma: `postgresql://postgres@localhost/postgres?host=<socket dir>`.
- Run `tests/fakes/upstream.py` from a copy with the port changed to `127.0.0.1:18000`.
- Create `tests/.artifacts/test.env` with `ensure_test_env` from `tests/helpers.bash`. From `gateway/`, with the variables from that file plus `DATABASE_URL`, `OPENROUTER_API_BASE=http://127.0.0.1:18000/v1`, `LITELLM_LOCAL_MODEL_COST_MAP=True` and `PYTHONDONTWRITEBYTECODE=1`, run `litellm --config config.yaml --host 127.0.0.1 --port 4000 --num_workers 1`. The first start takes about a minute.
- Put a stand-in `docker` that only does `exit 0` first on `PATH`, then `npx --yes bats@1.11.0 tests/drain.bats`.

The tests that need real Docker (compose config, `docker inspect`, restarts) cannot run this way, and the owner runs those on `sandbox`.

`tests/rapidselector.bats` and `tests/checks.bats` ran here on 2026-11-05 with the same stand-in `docker` and `tests/fakes/secrets_service.py` copied with its port changed to `127.0.0.1:18002`, started with `FAKE_SECRETS_FILE=tests/.artifacts/secrets.json` (a file holding `{}`); stop it by its process id afterwards.

**What runs here for `ops-scripts`** (2026-11-08), with copies of the fakes in a scratchpad, outside the repository, stopped by their process ids afterwards:
- No fakes needed: `npx --yes bats@1.11.0 tests/checks.bats tests/ops-logic.bats`.
- `tests/rapidselector.bats` and `tests/cleanup.bats --filter '^secrets'`: the fake secrets-service above, and a stand-in `docker` first on `PATH`.
- `tests/ops-wiring.bats`: also `tests/fakes/upstream.py` copied with `("0.0.0.0", 8000)` changed to `("127.0.0.1", 18000)`, started with `FAKE_GATEWAY_CONFIG=<repo>/gateway/config.yaml` and no `FAKE_MANAGEMENT_KEY` (the default `test-management-key` is what the wiring tests use). It also serves the gateway's read routes, so `status.sh`, `reconcile.sh` and `write-metrics.sh` run against it with `GATEWAY_PORT=18000`.
- Run that way on 2026-11-08: 74 tests and the 5 secrets tests. Everything else (the real gateway) runs only in the cloud Docker run.

Never use `pkill -f` or `pgrep -f` with a pattern from your own command in the Bash tool: it matches the tool's shell. It killed a command and caused a false test failure in the previous session.
