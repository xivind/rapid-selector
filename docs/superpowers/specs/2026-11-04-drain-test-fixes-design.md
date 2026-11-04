# Fixes to the drain test and the phase 0 procedure

Small change, made before any money is spent at level 3. Status: approved by the owner, 2026-11-04.

## Why

Tests B (D1) and A (D6) exist to show that the key limit and the prepaid balance stop spend, and how far past them spend can go. As written they can give a wrong or empty answer:

- OpenRouter reserves a call's worst-case cost before running it, about $0.049 for `qwen3.8-2.4t-a95b` at 8192 tokens. D1 would stop after about one call. D6 may stop with money left, because the budget for reservations is an unpublished share of the balance.
- `drain-balance.sh` counts any non-200 as "refused", so a passing 429 or 503 looks like a working limit, and then starts a burst worth up to about $0.25 that `--max-usd` does not cover.
- The burst only runs after a refusal, so it cannot show a call crossing a limit. One-at-a-time calls should not cross one either, since each reservation must fit first.

## Goals and non-goals

- **Goals:** a limit is only reported as working after a real limit refusal; spend stays within `--max-usd`; D6 gets close to zero; simultaneous calls test the crossing. Settles findings 26, 27, 28 and 29, and checks 31.
- **Non-goals:** the other deferred findings stay deferred, except for short notes in the procedure (21 and 30). No change to the gateway's configuration.
- **Anti-goal:** a result that reads as "limit works" when the limit was never reached.

## Approaches

1. **Procedure text only.** No code, but the false pass and the uncapped burst remain.
2. **Sort refusals and step down.** Shows that limits stop calls, not whether simultaneous calls get past them.
3. **Option 2 plus parallel rounds.** Also answers open questions 1 and 2. **Chosen by the owner, 2026-11-04.**

## Design: `scripts/drain-balance.sh`

**New flags:** `--max-tokens N` (default 8192) and `--parallel N` (default 5). `--parallel 1` stays available in case OpenRouter's reservations block simultaneous calls altogether.

**Each round** sends `min(parallel, calls left)` calls at once and prints one progress line: tokens, statuses, spend so far. The burst after the refusal is removed.

**Before each round:** stop with `max-usd` if `spent + calls × (max_tokens + 100) × output price` is above `--max-usd`. The price comes from `/model/info`; the 100 covers the short prompt. `--max-calls` now counts every call sent, not only the answered ones.

**After each round,** the most serious outcome decides:

| Answer | Meaning | What the script does |
|---|---|---|
| Anything not listed below | A fault, not a limit | Stops: `stopped: error`, stated as not a limit result |
| 422 with `budget_exceeded` | The gateway's budget, not OpenRouter's | Stops: `stopped: gateway-budget` |
| 402, or `openrouter_key_limit` or `openrouter_credits` in the body | A limit refusal | Halves `max_tokens`; below 16 it stops: `stopped: refused` |
| `openrouter_in_flight_budget` in the body | Temporary | Waits 10 seconds and repeats; after 6 rounds in a row with no answered call it stops: `stopped: in-flight` |
| All 200 | | Next round |

The gateway drops `Retry-After`, so the wait is fixed. The summary keeps its lines and shows up to 600 characters of each of the last answers, since `limit_source` comes late in the message.

## Design: tests

- `tests/fakes/upstream.py` gets modes for OpenRouter's documented refusal bodies, for refusing the first N calls, and for refusing above a token count.
- `tests/drain.bats` covers each row of the table, the two flags, the round check against `--max-usd`, and `--max-calls` counting refused calls. It replaces the burst test.
- That the gateway passes on the status and `limit_source` (finding 28) is asserted by those tests, through the real gateway.

## Design: `docs/test-procedures/phase-0.md`

- **New B1a:** run `tests/run.sh` on `sandbox` before B2. It also gives the first full level 1 run on arm64. It cannot run beside the real stack, because both use the same fixed container names. A guard against that is recorded as a new deferred finding, 32.
- **B1:** `chmod 600` on `.env` and the token file, and hex-only secrets using the commands in `.env.example` (findings 21 and 30).
- **C1:** the `production` merge is already done (#181); restarting Prometheus remains.
- **New C5, reboot check (29, 31):** after a reboot, ports 4000 and 4010 listen on the LAN address only, all services are healthy, and "database failing" has not fired after 10 minutes.
- **D1:** `--max-usd 0.10 --max-tokens 1024 --parallel 5`. Accepts 402 or 403, since the docs give both for a key limit. Stated cost stays up to about $0.10.
- **D3 and D6:** run `tests/check-prices.sh` first (29).
- **D6:** `--max-usd <balance + 1>`, with defaults for the rest. It may take a long time. It can end up to about $0.25 below zero if reservations do not protect the balance, within the $1 ceiling.
- **Alerts:** correct the text. D6 will not fire them: the budget rules need over $19.20 of `experiments`' $24 spent, and the failure rule watches only roles. The wrong reference to D5 is corrected too.
- **New D8 (Claude's proposal, accepted):** lower the budget with `BUDGET_TEAM_EXPERIMENTS=<just above spend> ./rapidselector.sh run-script scripts/setup-keys.sh`, run the smoke test so the gateway updates its metric (under $0.01), wait 16 minutes for the budget alert emails, and restore it by running `setup-keys.sh` again. It comes after the regular top-up (D7), since the smoke test needs a balance. The failure-rate rule stays unproven until it fires for real.

## Known limit of the result

OpenRouter's reservations apply only below an unpublished balance, and to newer accounts. Whatever D1 and D6 show about simultaneous calls holds for a small balance on a new account, and is recorded with that condition.

## Records

`docs/provider-facts.md` gets a dated entry with the current limits page and the gateway's behaviour. `docs/decisions.md` gets this decision and updates to findings 26 to 29 and 31, plus the new finding 32. `grafana/rapidselector-alerts.md` in the `production` repository has the same wrong note, and is corrected there in its own commit, with the owner's agreement.

## Left to the builder

The names of the fake upstream's modes, and the exact wording of the progress lines.

## Verification

Level 1 runs on `sandbox`, by the owner, because this machine has no Docker. The script's behaviour against real OpenRouter is only verified by D1 and D6.
