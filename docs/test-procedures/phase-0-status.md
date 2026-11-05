# Phase 0: where the walkthrough stands

A handoff between sessions, written 2026-11-04. Update "Next step" and the state tables as steps finish, and delete this file when phase 0 is verified. Results themselves go in `docs/decisions.md`; this file only says where we are.

## Next step: B6

Steps A1, A2, A3, B1a, B1, B2, B3, B4 and B5 are done. On 2026-11-05 the owner asked for `./rapidselector.sh up` to be always detached, the memory limits to go, and the README to cover setup. These are on `phase-0-walkthrough`, which `sandbox` is now on, and they work there. `tests/resilience.bats` was edited but has not been run, since it needs Docker and level 1 cannot run beside the real stack: run it at the next level 1 run. Everything is recorded. The real stack is running on `sandbox`, so level 1 must not be run there. **Do not regenerate the secret `rapidselector`:** the first start has happened, and `LITELLM_SALT_KEY` must not change.

## How we work through the procedure

These are the owner's instructions for this walkthrough, on top of `CLAUDE.md`:

- `docs/test-procedures/phase-0.md`, one step at a time: what to run or click, what they should see, what it costs. **Wait for their report before the next step.** Record every result in `docs/decisions.md`, and commit and push it.
- **Stop and ask before anything that spends money beyond the procedure's stated cost.** The ceiling is $6 of credit ($1 plus the $5 top-up), not counting D7's regular top-up.
- **The owner never pastes a secret value to Claude.** Names and statuses only.
- The owner is new to Compose. Plain language, complete commands, and say what each output should look like.
- The owner welcomes pushback and pushes back too: ask whether something is needed before proposing a change to a host. Example: the memory cgroup boot setting, proposed and then rightly dropped.
- Code changes use the superpowers skills and tests first.

## State of things

### OpenRouter

| What | State |
|---|---|
| Balance | $5.00, nothing spent yet. $7.25 paid |
| Inference key | `rapidselector-gateway`: limit $0.05, monthly reset. The value is in secrets-service, as `RAPIDSELECTOR_OPENROUTER_KEY` |
| Management key | None. Only tower needs one, in phase 1 |
| Auto top-up | Off, and no card on file (Google Pay through Stripe) |
| Zero data retention | All 5 toggles on, `ZDR only` under "All other models" and "Google" |
| Data training and the 1% discount | All off |
| Allowed providers | Cloudflare, CoreWeave, DeepInfra, SiliconFlow |

### `sandbox`

- Clone at `/home/pi/code/rapid-selector`, on `phase-0-walkthrough`. `.env` is filled in, and the secrets-service token is in `~/.config/rapidselector/secrets-service.token`.
- `jq` installed. Docker images downloaded (about 1.9 GB). `~/bats-core` holds bats 1.11.0, because `sandbox` has no Node, so `tests/run.sh` (which uses `npx`) does not work there. Use `~/bats-core/bin/bats tests/*.bats 2>&1 | tee ~/level1.log`.
- The real stack started at B2. `/boot/firmware/cmdline.txt` was not changed: the kernel's memory control stays off by the owner's decision.
- All 103 level 1 tests have passed there, across two runs (`docs/decisions.md`). Level 1 cannot run beside the real stack, because the container names clash.

### Repositories

- **`rapid-selector`:** PR #2 is merged to `main`. Branch **`phase-0-walkthrough`** is pushed but has no PR yet. It holds the records from A1 on, the Safety Retention check in `tests/check-prices.sh`, the always-detached `up`, the removal of the memory limits and the README's setup. **Merge it before D3, or `sandbox`'s `tests/check-prices.sh` will not have that check.** This machine's checkout is on that branch.
- **`production`:** the rapid-selector changes (#181) and the alert note (#183) are merged. This machine's checkout is on `main`, 2 commits behind, with a graphify file modified by its hook, not by us.

## To do before particular steps

- **Before D2, the owner decides the monthly limit (open question 37).** VAT was not in the 400 NOK budget: $34 of credit costs about $44.84, and 400 NOK buys about $26.50–30.30. Ask for the receipt's breakdown and check the exchange rate. Lowering the limit also means changing the LiteLLM budgets to stay below it ($32 global in `gateway/config.yaml`; $8 and $24 for the teams, $4 and $1 for the keys in `scripts/setup-keys.sh`), `docs/decisions.md`, and the procedure and alert notes that quote $19.20 (20% of $24), then running `setup-keys.sh` and testing. Fees also weigh on D7: if the minimum fee is real, a small top-up pays proportionally more.
- **Before D5, Claude must choose the temporary entry:** a real endpoint without zero data retention. The account now refuses it in up to three ways (the pin's `zdr: true`, `ZDR only`, and allowed providers). An endpoint at one of the four allowed hosts tests the data policy on its own, if one exists. Check `GET /api/v1/models/<model>/endpoints` against `/api/v1/endpoints/zdr`.
- **C1:** only the Prometheus restart remains. The job is merged in `production`; check it is pulled where Prometheus runs.
- **C2** runs in a separate local Claude Code session in the `production` repository.
- **C5, the reboot,** also settles deferred finding 31.
- **D1's expected result** is not known: whether simultaneous calls cross a key limit is what it tests. Key usage already includes B6's spend. What it shows holds for a small balance on a new account (`docs/provider-facts.md`).
- **E2:** Claude writes the restore commands then.

## Deferred, for the owner to decide

Findings 20–25, 30 and 32–36 in `docs/decisions.md`. None blocks the procedure. If finding 33's timing checks fail on the Pi in a later run, widen them.

## For developers on this machine

This Chromebook has no Docker, so `tests/run.sh` does not work here. The previous session ran `tests/drain.bats` and the upstream tests in `tests/fakes.bats` with real LiteLLM v1.106.6 and real Postgres outside Docker. That setup was in a scratchpad that is gone. To rebuild it, outside the repository:

- `uv venv` with Python 3.11, then install `litellm[proxy]==1.106.6`, `prisma`, `pgserver` and `prometheus_client`. Run `prisma generate --schema=<venv>/lib/python3.11/site-packages/litellm/proxy/schema.prisma`.
- Start Postgres with `pgserver.get_server(path, cleanup_mode=None)`. Its address needs a host for Prisma: `postgresql://postgres@localhost/postgres?host=<socket dir>`.
- Run `tests/fakes/upstream.py` from a copy with the port changed to `127.0.0.1:18000`.
- Create `tests/.artifacts/test.env` with `ensure_test_env` from `tests/helpers.bash`. From `gateway/`, with the variables from that file plus `DATABASE_URL`, `OPENROUTER_API_BASE=http://127.0.0.1:18000/v1`, `LITELLM_LOCAL_MODEL_COST_MAP=True` and `PYTHONDONTWRITEBYTECODE=1`, run `litellm --config config.yaml --host 127.0.0.1 --port 4000 --num_workers 1`. The first start takes about a minute.
- Put a stand-in `docker` that only does `exit 0` first on `PATH`, then `npx --yes bats@1.11.0 tests/drain.bats`.

The tests that need real Docker (compose config, `docker inspect`, restarts) cannot run this way, and the owner runs those on `sandbox`.

Never use `pkill -f` or `pgrep -f` with a pattern from your own command in the Bash tool: it matches the tool's shell. It killed a command and caused a false test failure in the previous session.
