# Phase 0: where the walkthrough stands

A handoff between sessions, written 2026-11-04 and rewritten on 2026-11-09, when tower's cleanup ended. Update it as steps finish, and delete it when phase 0 is verified. Results themselves go in `docs/decisions.md`; this file only says where we are.

## Where we are (2026-11-11, evening)

- **Merged into `main`** (`docs/decisions.md`, "Both branches merged"): PR #3, the phase 0 records (`1bf22d1`), then PR #4, the operator scripts (`f4b760d`), both with merge commits; both branches deleted on GitHub and here, and the worktree removed. **Records now go straight to `main`** (owner). Before the merge: every ruling of the plan's ledger reviewed (ruling 23 reversed, so tower is out of the living docs), and the cloud Docker run passed, 18 files and 193 tests.
- **Tower is dropped** (owner, 2026-11-07/08) and replaced by the operator scripts: design `docs/superpowers/specs/2026-11-08-scripts-instead-of-tower-design.md`, plan `docs/superpowers/plans/2026-11-08-scripts-instead-of-tower.md`, procedure `docs/test-procedures/ops-scripts.md` (done 2026-11-08/09). Tower is named only in `docs/decisions.md` and those three files.
- **Decided on 2026-11-08 and 09** (`docs/decisions.md`): the management key is optional; LiteLLM stays as the gateway (not to be reopened without new facts); `sandbox`'s node_exporter reads `/var/lib/node_exporter/textfile` (owned by `pi`); remote access is through Raspberry Pi Connect on another Pi, with two-factor authentication.
- **Phase 0:** A1–A3, B1a, B1–B6, C1–C5, D1–D8 and E1 are done and recorded. **rapid-selector stays on `sandbox`** (owner). E2 (restore) is parked in `docs/roadmap.md` (owner, 2026-11-11). E3 (first real use from Node-RED) is open.
- **The real stack runs on `sandbox`.** Level 1 must not be run there. **Do not regenerate the secret `rapidselector`:** `LITELLM_SALT_KEY` must not change.

## Next, in order (the owner picks)

1. **The `config/` folder:** the design `docs/superpowers/specs/2026-11-11-config-folder-design.md` is approved (2026-11-11). **Next: the plan, with `superpowers:writing-plans`**, then the build on a branch from `main`, tests first, a cloud Docker run, a PR, and the owner's procedure on `sandbox` (the design's 5 steps); then the docs cleanup, the `CLAUDE.md` cleanup and the user guide's upgrade section, in that order (the spec's "Next projects"). The Grafana panel and finding 44 are done, and `production` is pushed (`605ae6d`; `docs/decisions.md`).
2. **The README dry run** (`docs/roadmap.md`, phase 1).
3. **Benchmarking:** Open WebUI's arena and promptfoo, a brainstorm of its own (`docs/roadmap.md`). Search and documents in chat for selected roles are parked there too (2026-11-08).

## Things to remember

- **D1:** the key limit stops calls only after their spend is counted (86% past at D1); accepted by the owner. The fast stop is disabling the inference key in OpenRouter's dashboard (README, "Stopping all spending").
- **D5:** the account's allowed-provider list refused a non-ZDR host; the data policy on its own cannot be tested at the four allowed hosts.
- **D6:** the balance is not a hard stop: it went to −$0.19; principle 1 says "plus a small overshoot".
- **Config changes:** after changing `gateway/config.yaml`, run `./rapidselector.sh restart gateway`, which runs the rules check first and refuses with exit 5 on a broken rule; `up` does not reload it.
- **jq versions:** this machine has jq 1.6, the cloud sandbox 1.7. Tests compare numbers as values, not as printed text.
- **The scripts' gateway key** (`KEY_SCRIPTS`, user `scripts`) uses role `proxy_admin_viewer` with three read routes (`provider-facts.md`).
- **`reconcile.sh` covers completed UTC days only**, so today is never in it.
- **A reinstall of node_exporter on `sandbox`** from `production`'s setup script makes the textfile folder root's again; set it back to `pi`, or the cron job stops writing (`production`'s `prometheus/CLAUDE.md`).
- **Check the host, not the repository:** the procedure assumed `production`'s unit file was what `sandbox` ran, and guessed the unit's name; both were wrong (B6).

## How we work through a procedure

These are the owner's instructions for walkthroughs, on top of `CLAUDE.md`:

- One step at a time: what to run or click, what they should see, what it costs. **Wait for their report before the next step.** Record every result in `docs/decisions.md`, and commit and push it.
- **Stop and ask before anything that spends money beyond the procedure's stated cost.**
- **The owner never pastes a secret value to Claude.** Names and statuses only.
- The owner is new to Compose. Plain language, complete commands, and say what each output should look like.
- The owner welcomes pushback and pushes back too: ask whether something is needed before proposing a change to a host.
- Code changes use the superpowers skills and tests first.
- **Pasting is fragile on the owner's terminal:** keep commands to short lines, never ask for a heredoc or indented code to be pasted, and put anything longer in a committed script the owner pulls. Run a silent `read -rs` line on its own.
- Every secret goes through `./rapidselector.sh run-script bash -c '…'` with the header on stdin (`curl -H @-`), and output that could hold a key goes through `sed -E "s/sk-[A-Za-z0-9_-]+/sk-REDACTED/g"`.

## State of things

### OpenRouter

| What | State |
|---|---|
| Balance | $34.81 at B1 (2026-11-08), plus the owner's chats and B5's $0.00000978 since |
| Inference key | `rapidselector-gateway`: limit $35, monthly reset; $5.19 used in November. The value is in secrets-service, as `RAPIDSELECTOR_OPENROUTER_KEY` |
| Management key | `rapidselector-scripts` (renamed from `rapidselector-tower` at A8), expires **2027-11-07** 09:41 UTC (`OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT` in `sandbox`'s `.env`). The value is in secrets-service, as `OPENROUTER_MANAGEMENT_KEY` |
| Auto top-up | Off, and no card on file (Google Pay through Stripe) |
| Zero data retention | All 5 toggles on, `ZDR only` under "All other models" and "Google" |
| Data training and the 1% discount | All off |
| Allowed providers | Cloudflare, CoreWeave, DeepInfra, SiliconFlow |
| Account | Two-factor authentication on (2026-11-11), and on the Google account it signs in with. The workspace, renamed "Rapid-selector Workspace", holds only `rapidselector-gateway` |

### `sandbox`

- Clone at `/home/pi/code/rapid-selector`, on **`main`** (switched by the owner on 2026-11-11 in the evening, at `fd56dd3`; the local `ops-scripts` deleted; no restart needed, as only docs changed since `449297d`). `.env` is filled in (no `TOWER_` lines), and the secrets-service token is in `~/.config/rapidselector/secrets-service.token`. The secret `rapidselector` has 11 fields: the 9 from phase 0, `OPENROUTER_MANAGEMENT_KEY` and `KEY_SCRIPTS`.
- Running: `chat`, `db` and `gateway`, all healthy; volumes `rapidselector_chatdata` and `rapidselector_pgdata`. Unused images and the build cache were removed at A7b.
- node_exporter (`prometheusexporter-pi`) runs with the textfile flag; `pi`'s crontab runs `scripts/write-metrics.sh` at :17 every hour, logging to `journalctl -t rapidselector-metrics`.
- `jq` installed. `~/bats-core` holds bats 1.11.0 (`sandbox` has no Node). Level 1 cannot run beside the real stack, because the container names clash.
- `/boot/firmware/cmdline.txt` was not changed: the kernel's memory control stays off by the owner's decision.

### Repositories

- **`rapid-selector`:** PRs #3 and #4 merged on 2026-11-11 (`f4b760d`). This machine's checkout is on `main`, with no worktrees; records are committed to `main` directly (owner). `main` is the only branch, here and on GitHub (`drain-test-fixes`, PR #2's, deleted 2026-11-11). `tower-part-1a` is deleted, locally and on GitHub (A11, A12).
- **`production`:** this machine's checkout (`~/code/production`) is on `main`, up to date, with graphify files modified by its hook, not by us. Its local branch `rapidselector-alert-note` tracks `origin`. Pushed to `main` on 2026-11-09 with the owner's permission: `1abfa10`, the note in `prometheus/CLAUDE.md` on `sandbox`'s textfile folder. Task 14's commits followed the same way, last `6d76e18` on 2026-11-10 (the alert rules' counting). GitHub reports 8 Dependabot alerts on `production`'s default branch (seen at that push; not ours).

## To do before particular steps

- **E2:** parked in `docs/roadmap.md` (owner, 2026-11-11), with when to take it up; Claude writes the restore commands then.

## Deferred, for the owner to decide

Findings 20–25, 30, 32–36, 38, 39 and 41 in `docs/decisions.md` (42 is moot; 40 and 43 were fixed on 2026-11-10; 44 was settled with no change on 2026-11-11). None blocks the plan. If finding 33's timing checks fail on the Pi in a later run, widen them.

## For developers on this machine

This Chromebook has no Docker, so `tests/run.sh` does not work here; the cloud Docker run covers the rest. What runs here, with copies of the fakes in a scratchpad, outside the repository, stopped by their process ids afterwards:

- No fakes needed: `npx --yes bats@1.11.0 tests/ops-logic.bats tests/smoke-args.bats`.
- `tests/rapidselector.bats` and `tests/checks.bats`: `tests/fakes/secrets_service.py` copied with `("0.0.0.0", 8002)` changed to `("127.0.0.1", 18002)`, started with `FAKE_SECRETS_FILE=<repo>/tests/.artifacts/secrets.json` (a file holding `{}`), and a stand-in `docker` (`exit 0`) first on `PATH`. 47/47 on 2026-11-09.
- `tests/ops-wiring.bats`: also `tests/fakes/upstream.py` copied with `("0.0.0.0", 8000)` changed to `("127.0.0.1", 18000)`, started with `FAKE_GATEWAY_CONFIG=<repo>/gateway/config.yaml` and no `FAKE_MANAGEMENT_KEY`. It also serves the gateway's read routes, so `status.sh`, `reconcile.sh` and `write-metrics.sh` run against it with `GATEWAY_PORT=18000`.
- `tests/drain.bats` and the upstream tests in `tests/fakes.bats` once ran here with real LiteLLM v1.106.6 and Postgres outside Docker (`uv venv` with Python 3.11, `litellm[proxy]==1.106.6`, `prisma`, `pgserver`, `prometheus_client`; see this file's history for the steps).

Never use `pkill -f` or `pgrep -f` with a pattern from your own command in the Bash tool: it matches the tool's shell.
