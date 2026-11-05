# Phase 0: where the walkthrough stands

A handoff between sessions, written 2026-11-04. Update "Next step" and the state tables as steps finish, and delete this file when phase 0 is verified. Results themselves go in `docs/decisions.md`; this file only says where we are.

## Next step: D6 (the owner decides when), and D3's last call another day

`gpt-oss-20b@deepinfra` got 429 from DeepInfra (`engine_overloaded`) three times; the other ten passed D3 and D4 (`docs/decisions.md`). If it answers, its host should show DeepInfra on OpenRouter's Logs page.

D1 is recorded: the key limit stops calls, but only after spend is counted, so it went 86% past. The owner accepted that (`docs/decisions.md`).

All of A and B, and C1 to C4, are done. C5 waits for the move to `webserver`, by the owner's decision, and phase 0 is not verified until it has passed. On 2026-11-05 the owner asked for `./rapidselector.sh up` to be always detached, the memory limits to go, and the README to cover setup. These are on `phase-0-walkthrough`, which `sandbox` is now on, and they work there. `tests/resilience.bats` was edited but has not been run, since it needs Docker and level 1 cannot run beside the real stack: run it at the next level 1 run. Everything is recorded. The real stack is running on `sandbox`, so level 1 must not be run there. **Do not regenerate the secret `rapidselector`:** the first start has happened, and `LITELLM_SALT_KEY` must not change.

## Tower part 1: design in progress (brainstorming, 2026-11-05)

Started while phase 0 waits for D6. Decided with the owner, all in `docs/decisions.md`: tower shows every setting and changes none (option B); look B, distinctive; stack 1 (FastAPI, Jinja2, own CSS, server-side SVG, htmx, Peewee and SQLite, pytest); USD only; today, this week (from Monday 00:00 UTC) and this month, with Grafana the same and longer; no history beyond that in tower; a "Log" section for kill switch changes and balance snapshots; the management key expires after a year, with a warning 30 days before. The arena and promptfoo wait (`docs/roadmap.md`, phase 2). Mockups are in `.superpowers/brainstorm/` (not committed). The docs research is in `docs/provider-facts.md` (2026-11-05 entries).

**Part 1a's design is approved** (2026-11-05): `docs/superpowers/specs/2026-11-05-tower-part-1a-design.md`. Next: its plan (superpowers:writing-plans), before any code. Building waits for D6 to D8 unless the owner decides otherwise. Part 1b's design was started the same day. Building waits until D6 to D8 are done, unless the owner decides otherwise.

Open points:
- **OpenRouter's account settings** are left out of tower, by the owner's decision: no API, and a hand-kept record would go stale.
- **Kill switch level 1** has to block each virtual key in turn (`/key/block`), as no call blocks them all; tower must also block keys added later. Releasing unblocks exactly those it blocked.
- **Tower's gateway key:** a key owned by a `proxy_admin` user, narrowed with `allowed_routes`, instead of the master key (question 17). To try at level 1.
- **Usage per role and model:** from `/user/daily/activity` or `/spend/logs`; to try at level 1 whether roles appear by their name. OpenRouter's `/api/v1/activity` covers completed days only, so today comes from the gateway and the key's `usage_daily`.
- **Editing (part 1b), decided 2026-11-05:** models must then live only in the gateway's database, as a same-named model in `config.yaml` would be load-balanced with it (`provider-facts.md`). `config.yaml` keeps the general settings; the starting set becomes a seed tower loads on a fresh install. First thing to try: that `provider`, prices and `max_tokens` can be set through `/model/new`. Tower warns before renaming or removing a role a key uses.
- **Order agreed with the owner:** design part 1a (viewing, kill switch, scheduled price check and smoke test) first, part 1b (editing) after.
- **D1 bears on the kill switch:** the key limit stops calls late, so level 2 (disable the key) and level 1 are the fast stops; whether a disable takes effect at once is not documented.

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
| Balance | About $4.91: $0.00000978 spent at B6 and $0.0932 at D1. $7.25 paid |
| Inference key | `rapidselector-gateway`: limit $35 since D2, monthly reset. The value is in secrets-service, as `RAPIDSELECTOR_OPENROUTER_KEY` |
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

- **C5, the reboot,** also settles deferred finding 31.
- **D1's expected result** is not known: whether simultaneous calls cross a key limit is what it tests. Key usage already includes B6's spend. What it shows holds for a small balance on a new account (`docs/provider-facts.md`).
- **E1:** the "Also change" part of `grafana/rapidselector-alerts.md` in `production`, raising the backup count from 9 to 11, was held back from C2: the two new jobs have no `backup_last_success_timestamp_seconds` until their first success, so raising it earlier fires "Backup missing".
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
