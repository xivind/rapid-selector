# Phase 0: where the walkthrough stands

A handoff between sessions, written 2026-11-04 and last updated 2026-11-06. Update "Next step" and the state tables as steps finish, and delete this file when phase 0 is verified. Results themselves go in `docs/decisions.md`; this file only says where we are.

## Where we are (2026-11-06)

- **Phase 0:** A1–A3, B1a, B1–B6, C1–C5, D1, D2, D4, D5 and E1 are done and recorded in `docs/decisions.md`. D3 passed for 10 of 11 names. **rapid-selector stays on `sandbox`** (owner, 2026-11-06).
- **E1 (2026-11-06):** chat now runs Open WebUI's slim image (about 510 MiB less memory), the old model cache is deleted from its volume, and the chat backup leaves out `cache/` (1.08 MB, not 1.1 GB). `min_bytes` and the backup count of 11 are set in `production`.
- **Tower:** the designs for part 1a (see, stop and check) and part 1b (full editing of models, roles, allowed names and budgets) are **approved**: `docs/superpowers/specs/2026-11-05-tower-part-1a-design.md` and `…-tower-part-1b-design.md`. Every decision behind them is in `docs/decisions.md` (2026-11-05 entries). No plan or code yet.
- **The real stack runs on `sandbox`.** Level 1 must not be run there. **Do not regenerate the secret `rapidselector`:** `LITELLM_SALT_KEY` must not change.

## Next, in order (the owner picks)

1. **Check the 06:00 backup of 2026-11-07:** both jobs status 1, the chat tar around 1 MB, and "Backup missing" still `Normal`.
2. **D3's last name, `gpt-oss-20b@deepinfra`:** it got 429 three times (DeepInfra `engine_overloaded`, `upstream_provider_shared_pool`). Call it once, on `sandbox` in `~/code/rapid-selector`: `./rapidselector.sh run-script scripts/smoke-test.sh --name gpt-oss-20b@deepinfra`. If it answers, its host on OpenRouter's Logs page should be DeepInfra. If it keeps failing over days, the owner decides whether to re-pin it.
3. **D6, test A, empty balance,** when the owner chooses: `tests/check-prices.sh` first, then `drain-balance.sh --max-usd <balance + 1> --max-calls 2000`. Spends the rest of the balance (about $4.91) and up to about $0.25 below zero. Then D7 (regular top-up) and D8 (budget alerts).
4. **Tower part 1a's plan** (superpowers:writing-plans), then part 1b's. Building waits until D6–D8 are done, unless the owner decides otherwise.
5. **Merge `phase-0-walkthrough` into `main`** when the owner says: open the PR then. `sandbox` is on that branch.

## Things to remember

- **D1:** the key limit stops calls only after their spend is counted (86% past at D1); accepted by the owner. The gateway's budgets stay below the key limit, and tower's kill switch is the fast stop.
- **D5:** the account's allowed-provider list refused a non-ZDR host; the data policy on its own cannot be tested at the four allowed hosts, as none has an ordinary endpoint without zero data retention.
- **Config changes:** the gateway reads `gateway/config.yaml` from a mounted file, so after changing it run `./rapidselector.sh restart gateway`; `up` does not reload it.
- **`tests/resilience.bats`** was edited (memory limits gone) but not run: run it at the next level 1 run.
- **Findings 38 and 39** (Hugging Face fetch, LiteLLM's own retries) are new and open in `docs/decisions.md`.
- **Tower, to try first when building:** usage per role from `/user/daily/activity` or `/spend/logs`; a `proxy_admin` key with `allowed_routes` (question 17); whether the management key is listed with its expiry; for 1b, that database models resolve `os.environ/RAPIDSELECTOR_OPENROUTER_KEY` and accept the pin, prices and `max_tokens` (if not, stop and ask the owner), and that the `/openrouter` pass-through stays refused.
- **Mockups** from the design talk are in `.superpowers/brainstorm/` (not committed); the visual companion is stopped.

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
| Management key | None. Only tower needs one, in phase 1 |
| Auto top-up | Off, and no card on file (Google Pay through Stripe) |
| Zero data retention | All 5 toggles on, `ZDR only` under "All other models" and "Google" |
| Data training and the 1% discount | All off |
| Allowed providers | Cloudflare, CoreWeave, DeepInfra, SiliconFlow |

### `sandbox`

- Clone at `/home/pi/code/rapid-selector`, on `phase-0-walkthrough`, pulled after D5. `.env` is filled in, and the secrets-service token is in `~/.config/rapidselector/secrets-service.token`.
- `jq` installed. Docker images downloaded (about 1.9 GB). `~/bats-core` holds bats 1.11.0, because `sandbox` has no Node, so `tests/run.sh` (which uses `npx`) does not work there. Use `~/bats-core/bin/bats tests/*.bats 2>&1 | tee ~/level1.log`.
- The real stack started at B2. `/boot/firmware/cmdline.txt` was not changed: the kernel's memory control stays off by the owner's decision.
- All 103 level 1 tests have passed there, across two runs (`docs/decisions.md`). Level 1 cannot run beside the real stack, because the container names clash.

### Repositories

- **`rapid-selector`:** PR #2 is merged to `main`. Branch **`phase-0-walkthrough`** is pushed, with no PR yet. It holds the records from A1 on, the Safety Retention check, the always-detached `up`, the removal of the memory limits, the README's setup, the `llm` alias dropped, and both tower designs. This machine's checkout is on that branch.
- **`production`:** the rapid-selector changes (#181) and the alert note (#183) are merged. On 2026-11-05 Claude pushed two small commits straight to `main`, with the owner's permission: the alert group named `LLM`, and the `llm` line removed from `nodered/create-container-nodered.sh`. This machine's checkout is on `main`, up to date, with graphify files modified by its hook, not by us. `home-assistant` and `messagebroker` pulled `main` during C1 and C4.

## To do before particular steps

- **E2:** Claude writes the restore commands then. The backup has no `cache/`, and the slim image needs none.

## Deferred, for the owner to decide

Findings 20–25, 30, 32–36 and 38–40 in `docs/decisions.md`. None blocks the procedure. If finding 33's timing checks fail on the Pi in a later run, widen them.

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
