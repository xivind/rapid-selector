# Phase 0: where the walkthrough stands

A handoff between sessions, written 2026-11-04 and last updated midday on 2026-11-07. Update "Next step" and the state tables as steps finish, and delete this file when phase 0 is verified. Results themselves go in `docs/decisions.md`; this file only says where we are.

## Where we are (midday 2026-11-07)

- **Phase 0:** A1–A3, B1a, B1–B6, C1–C5, D1–D8 and E1 are done and recorded in `docs/decisions.md`. **rapid-selector stays on `sandbox`** (owner). E2 moves to after tower part 1b. E3 (first real use from Node-RED) is open.
- **D6:** the balance is not a hard stop: it went to −$0.19 across two drain runs; `CLAUDE.md` principle 1 now says "plus a small overshoot". On 2026-11-07 a line under the three layers says "hard" means enforced by OpenRouter, not exact to the cent (`docs/decisions.md`).
- **D7:** $35 topped up; balance $34.81.
- **D8 done:** both budget rules fired, emailed (after Mailgun was fixed and the rules paused and resumed) and cleared at 22:24. `experiments` is back at $24.
- **Tower part 1a is built** on branch **`tower-part-1a`** (pushed; worktree `.worktrees/tower-part-1a` on this machine), subagent-driven: all 13 tasks reviewed, the final whole-branch review's fixes done and re-reviewed. 160 unit tests pass (`cd tower && uv run pytest`), and the third Docker run passed the whole level 1 suite (141 tests) at `5877b72` with no changes. The ledger is `.worktrees/tower-part-1a/.superpowers/sdd/2026-11-06-tower-part-1a/progress.md` (not in git). In `production`, branch **`rapidselector-tower`** (local only, not pushed) holds tower's backup job, Prometheus target and alert note, with a summary and description per rule (5 commits, 55b3781..8e36599; the checkout itself is back on `main`): merge it only when tower runs on `sandbox`, since its `jobs.conf` line fails the nightly run until the export word is installed there.
- **Tower's look was revised on 2026-11-07** and the owner signed it off (`docs/decisions.md`): status panel, lights and badges, comparisons and ◆ on Cost and Usage, Setup in tabs. Built on `tower-part-1a` (`5f4f393..eece57e`), 203 unit tests pass, and the cloud Docker run at `eece57e` passed (203 unit, 141 level 1); the plan and its workspace are closed. Afterwards, by the owner's look (`docs/decisions.md`): lights differ in shape (`fee4518`), Cost bars show share of spend, a reconciliation note and a legend on Setup (`fb152b8`); 208 unit tests, CSS and templates only. Then a reason line inside a Setup tab when its light is yellow or red (`672a24e`), the open tab's status line removed (`9ef162b`), and the reason line starting with a capital (`791b2b9`, the branch's head). Design `docs/superpowers/specs/2026-11-07-tower-look-revision-design.md`, plan `docs/superpowers/plans/2026-11-07-tower-look-revision.md` (done). To look at tower without Docker: `cd .worktrees/tower-part-1a/tower && uv run python tests/preview.py`, then `http://localhost:8765`, password `look`.
- **The real stack runs on `sandbox`.** Level 1 must not be run there. **Do not regenerate the secret `rapidselector`:** `LITELLM_SALT_KEY` must not change.

## Next, in order (the owner picks)

1. **Tower's test procedure on `sandbox`** (`docs/test-procedures/tower-1a.md` on `tower-part-1a`), one step at a time. **Done and recorded:** step 0 (Compose v5.7.0), the switch to `tower-part-1a`, A1–A4, B1–B4, C1, C3 with A3. **Stopped in C2** (`docs/decisions.md`, "C2, cost against OpenRouter (in progress…)"): balance and totals match, but the per-day lines show two bugs in tower:
   - **Bug 1, cause found, fix not made:** `reconcile_days` (`tower/tower/summary.py`) cuts the gateway's host to before the `/` (`_slug_host`), while OpenRouter's activity `provider_name` is the full endpoint tag (`siliconflow/fp8`), so every model shows as two lines. Fix test first with the real shape: compare the full tag on both sides, as `checks.py` does; fix the guessed sample in `tests/test_summary.py`; record the field's real form in `provider-facts.md`.
   - **Bug 2, cause not found:** `gpt-oss-120b@coreweave`'s spend is missing on the gateway side, and `@deepinfra`'s is about that much larger (11-05 and 11-06). Three names share `openai/gpt-oss-120b` (`chat`, `gpt-oss-120b@deepinfra`, `gpt-oss-120b@coreweave`). **First, ask the owner for the evidence they had not yet given:** Usage page, month columns, calls and spend for those three names; the Cost page's reconciliation line; whether any per-day line is red. If Usage shows CoreWeave calls, the fault is in tower's mapping; if not, LiteLLM's `/user/daily/activity` files them under another name, which makes the Usage page wrong too and needs a look at LiteLLM's current docs. Use `superpowers:systematic-debugging`: no fix before the cause.
   - After both fixes (tests first, all unit tests pass): push to `tower-part-1a`; the owner runs `git pull` and `./rapidselector.sh up --build tower` on `sandbox`, and C2 is repeated. A cloud Docker run is probably not needed for a change inside `summary.py`; say so and let the owner decide.
   - **Then C4, C5, C6, D1–D4** (the smoke test spends under $0.01), **E1–E7** (the kill switch; under $0.001 each with the probe), **F1–F2**, **G1–G7** (`production`).
2. **Merging:** `phase-0-walkthrough` into `main`, then `tower-part-1a`, when the owner says; open the PRs then. `sandbox` is now on `tower-part-1a`.
3. **After the merge:** the README dry run, and two-factor authentication on the OpenRouter account (both in `docs/roadmap.md`, phase 1).
4. **Tower part 1b's plan**, after 1a has passed on `sandbox`.

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
