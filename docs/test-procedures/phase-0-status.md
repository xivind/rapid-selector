# Phase 0: where the walkthrough stands

A handoff between sessions, written 2026-11-04 and last updated on 2026-11-08. Update "Next step" and the state tables as steps finish, and delete this file when phase 0 is verified. Results themselves go in `docs/decisions.md`; this file only says where we are.

## Where we are (2026-11-08)

- **Tower is dropped** (owner, 2026-11-07/08, `docs/decisions.md`: "Tower paused…" and "Scripts instead of tower, designed and approved"). It is replaced by operator scripts: design `docs/superpowers/specs/2026-11-08-scripts-instead-of-tower-design.md`, plan `docs/superpowers/plans/2026-11-08-scripts-instead-of-tower.md` (15 tasks). The two tower paragraphs below describe what is still on `sandbox`, in `production` and on this machine until the plan's cleanup removes it; tower keeps running read-only on `sandbox` until then.

- **Phase 0:** A1–A3, B1a, B1–B6, C1–C5, D1–D8 and E1 are done and recorded in `docs/decisions.md`. **rapid-selector stays on `sandbox`** (owner). E2 moves to after tower part 1b. E3 (first real use from Node-RED) is open.
- **D6:** the balance is not a hard stop: it went to −$0.19 across two drain runs; `CLAUDE.md` principle 1 now says "plus a small overshoot". On 2026-11-07 a line under the three layers says "hard" means enforced by OpenRouter, not exact to the cent (`docs/decisions.md`).
- **D7:** $35 topped up; balance $34.81.
- **D8 done:** both budget rules fired, emailed (after Mailgun was fixed and the rules paused and resumed) and cleared at 22:24. `experiments` is back at $24.
- **Tower part 1a is built** on branch **`tower-part-1a`** (pushed; worktree `.worktrees/tower-part-1a` on this machine), subagent-driven: all 13 tasks reviewed, the final whole-branch review's fixes done and re-reviewed. 160 unit tests pass (`cd tower && uv run pytest`), and the third Docker run passed the whole level 1 suite (141 tests) at `5877b72` with no changes. The ledger is `.worktrees/tower-part-1a/.superpowers/sdd/2026-11-06-tower-part-1a/progress.md` (not in git). In `production`, branch **`rapidselector-tower`** (local only, not pushed) holds tower's backup job, Prometheus target and alert note, with a summary and description per rule (5 commits, 55b3781..8e36599; the checkout itself is back on `main`): merge it only when tower runs on `sandbox`, since its `jobs.conf` line fails the nightly run until the export word is installed there.
- **Tower's look was revised on 2026-11-07** and the owner signed it off (`docs/decisions.md`): status panel, lights and badges, comparisons and ◆ on Cost and Usage, Setup in tabs. Built on `tower-part-1a` (`5f4f393..eece57e`), 203 unit tests pass, and the cloud Docker run at `eece57e` passed (203 unit, 141 level 1); the plan and its workspace are closed. Afterwards, by the owner's look (`docs/decisions.md`): lights differ in shape (`fee4518`), Cost bars show share of spend, a reconciliation note and a legend on Setup (`fb152b8`); 208 unit tests, CSS and templates only. Then a reason line inside a Setup tab when its light is yellow or red (`672a24e`), the open tab's status line removed (`9ef162b`), and the reason line starting with a capital (`791b2b9`, the branch's head). Design `docs/superpowers/specs/2026-11-07-tower-look-revision-design.md`, plan `docs/superpowers/plans/2026-11-07-tower-look-revision.md` (done). To look at tower without Docker: `cd .worktrees/tower-part-1a/tower && uv run python tests/preview.py`, then `http://localhost:8765`, password `look`.
- **The real stack runs on `sandbox`.** Level 1 must not be run there. **Do not regenerate the secret `rapidselector`:** `LITELLM_SALT_KEY` must not change.

## Next, in order (the owner picks)

1. **Progress, 2026-11-08:** Tasks 1–11 are built on `ops-scripts` (pushed, `61bf866..86fefad`), ledger `.worktrees/ops-scripts/.superpowers/sdd/2026-11-08-scripts-instead-of-tower/progress.md` (not in git; its `Ruling:` lines go to the owner). Run here: `tests/checks.bats` 20/20, `tests/ops-logic.bats` 21/21, `tests/rapidselector.bats` 16/16 and `tests/cleanup.bats`'s 5 secrets tests (local fake secrets-service), and `status.sh`, `reconcile.sh` and `write-metrics.sh` against local fakes. **Not yet verified:** every Docker test (`tests/ops-scripts.bats`, `gateway-api.bats`, `keys.bats`, `cleanup.bats`'s user tests, the rest of level 1). Next: Task 12, the cloud Docker run (the owner opens it), and Task 13, the whole-branch review.
1. **Build the plan `docs/superpowers/plans/2026-11-08-scripts-instead-of-tower.md`, native** (the owner's choice, 2026-11-08): Claude implements every task in the session with `superpowers:executing-plans`, tests first, in a worktree `.worktrees/ops-scripts` on a new branch `ops-scripts` from `phase-0-walkthrough`; one fresh reviewer on the whole branch at the end (Task 13). Tasks 1–11 on this machine (no Docker: only `tests/ops-logic.bats`, `tests/checks.bats` and `bash -n` run here); Task 12 is a cloud Docker run in a claude.ai/code session the owner opens; then the owner's procedure `docs/test-procedures/ops-scripts.md` on `sandbox` (cleanup first, **only after the build is pushed and tested**), Grafana's alerts and dashboard from a `production` session (Task 14), and the onboarding to LiteLLM and OpenRouter together (Task 15). Records go on `phase-0-walkthrough`.
2. **Merging:** `phase-0-walkthrough` into `main`, then `ops-scripts`, when the owner says; open the PRs then. `tower-part-1a` is never merged: it is deleted in the cleanup, with no tag. `sandbox` is on `tower-part-1a` until the cleanup's step A2.
3. **After the merge:** the README dry run, and two-factor authentication on the OpenRouter account (both in `docs/roadmap.md`, phase 1).
4. **Benchmarking:** Open WebUI's arena and promptfoo, a brainstorm of its own after the plan (`docs/roadmap.md`). Tower part 1b is dropped.

## Things to remember

- **D1:** the key limit stops calls only after their spend is counted (86% past at D1); accepted by the owner. The gateway's budgets stay below the key limit, and tower's kill switch is the fast stop.
- **D5:** the account's allowed-provider list refused a non-ZDR host; the data policy on its own cannot be tested at the four allowed hosts, as none has an ordinary endpoint without zero data retention.
- **Config changes:** the gateway reads `gateway/config.yaml` from a mounted file, so after changing it run `./rapidselector.sh restart gateway`; `up` does not reload it.
- **`tests/resilience.bats`** was edited (memory limits gone) but not run: run it at the next level 1 run.
- **Findings 38 and 39** (Hugging Face fetch, LiteLLM's own retries) are new and open in `docs/decisions.md`.
- **Tower 1a facts found:** usage per name from `/user/daily/activity`; tower's own `proxy_admin` key with `allowed_routes` works (question 17); OpenRouter's key list needs `include_disabled=true`; level 1 does not block LiteLLM's master key or the admin UI's own session key (owner accepted). **For 1b, to try first:** database models resolve `os.environ/RAPIDSELECTOR_OPENROUTER_KEY` and accept the pin, prices and `max_tokens` (if not, stop and ask the owner), and that the `/openrouter` pass-through stays refused.
- **Mockups** from the design talks are in `.superpowers/brainstorm/` (not committed); the 2026-11-07 ones, versions 2 to 4 of tower's look, are in `.superpowers/brainstorm/4355-1794004845/content/`. The visual companion is stopped.

## How we work through the procedure

These are the owner's instructions for this walkthrough, on top of `CLAUDE.md`:

- `docs/test-procedures/phase-0.md`, one step at a time: what to run or click, what they should see, what it costs. **Wait for their report before the next step.** Record every result in `docs/decisions.md`, and commit and push it.
- **Stop and ask before anything that spends money beyond the procedure's stated cost.** The ceiling is $6 of credit ($1 plus the $5 top-up), not counting D7's regular top-up.
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
| Management key | `rapidselector-tower`, created 2026-11-07, expires **2027-11-07** 09:41 UTC (set in `sandbox`'s `.env` as `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT`, since tower cannot read it from the API). The value is in secrets-service, as `OPENROUTER_MANAGEMENT_KEY` |
| Auto top-up | Off, and no card on file (Google Pay through Stripe) |
| Zero data retention | All 5 toggles on, `ZDR only` under "All other models" and "Google" |
| Data training and the 1% discount | All off |
| Allowed providers | Cloudflare, CoreWeave, DeepInfra, SiliconFlow |

### `sandbox`

- Clone at `/home/pi/code/rapid-selector`, on **`tower-part-1a`** since 2026-11-07, at `791b2b9`. Tower runs there (`http://sandbox:4020`, healthy, about 105 MiB or less). `.env` is filled in, and the secrets-service token is in `~/.config/rapidselector/secrets-service.token`.
- `jq` installed. Docker images downloaded (about 1.9 GB). `~/bats-core` holds bats 1.11.0, because `sandbox` has no Node, so `tests/run.sh` (which uses `npx`) does not work there. Use `~/bats-core/bin/bats tests/*.bats 2>&1 | tee ~/level1.log`.
- The real stack started at B2. `/boot/firmware/cmdline.txt` was not changed: the kernel's memory control stays off by the owner's decision.
- All 103 level 1 tests have passed there, across two runs (`docs/decisions.md`). Level 1 cannot run beside the real stack, because the container names clash.

### Repositories

- **`rapid-selector`:** PR #2 is merged to `main`. Branch **`phase-0-walkthrough`** is pushed, with no PR yet. It holds the records from A1 on, the Safety Retention check, the always-detached `up`, the removal of the memory limits, the README's setup, the `llm` alias dropped, and both tower designs. This machine's checkout is on that branch.
- **`production`:** the rapid-selector changes (#181) and the alert note (#183) are merged. On 2026-11-05 Claude pushed two small commits straight to `main`, with the owner's permission: the alert group named `LLM`, and the `llm` line removed from `nodered/create-container-nodered.sh`. This machine's checkout is on `main`, up to date, with graphify files modified by its hook, not by us. `home-assistant` and `messagebroker` pulled `main` during C1 and C4. On 2026-11-06, after D8, Claude pushed `dec5f60` to `main` with the owner's permission: a summary and description for each LLM rule in `grafana/rapidselector-alerts.md` (then `f3c5d72`, full rule names), applied to the 8 rules by a `production` session through the Grafana MCP, nothing else changed.

## To do before particular steps

- **E2:** moved to after tower part 1b is deployed (owner, 2026-11-06). Claude writes the restore commands then. The backup has no `cache/`, and the slim image needs none.

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

Never use `pkill -f` or `pgrep -f` with a pattern from your own command in the Bash tool: it matches the tool's shell. It killed a command and caused a false test failure in the previous session.
