# Drain test fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `scripts/drain-balance.sh` and `docs/test-procedures/phase-0.md` give true answers about the key limit and the balance, before real money is spent at level 3.

**Architecture:** The script becomes one loop of parallel rounds, with a check before each round and a decision after it. The fake upstream learns OpenRouter's documented refusals, so the tests go through the real gateway. The procedure and records follow.

**Tech Stack:** bash, jq, curl, bats 1.11.0, Python standard library (fake upstream), LiteLLM v1.106.6.

**Spec:** `docs/superpowers/specs/2026-11-04-drain-test-fixes-design.md`

## Global Constraints

- Branch `drain-test-fixes`. It reaches `main` only after level 1 passes on `sandbox`.
- This machine has no Docker. Level 1 is verified by the owner on `sandbox`, before step B2, and never with the real stack up: both use the same fixed container names.
- No real OpenRouter calls while building. The live check `tests/check-prices.sh` is free and allowed.
- Everything in English. Commit messages end with the attribution line from the session.
- No new dependencies in the repository.
- Worst-case round cost: `calls × (max_tokens + 100) × output price`, with the price from `/model/info` at `.model_info.output_cost_per_token`.
- Floor for `max_tokens` is 16; in-flight wait is 10 seconds (`DRAIN_RETRY_WAIT` overrides it for tests); at most 6 rounds in a row with no answered call.

## Review Focus

- A round with both 200s and refusals: the answered calls count toward spend and the size is still halved (test in Task 2).
- A connection failure, curl's `000`: a fault, never a limit refusal (test in Task 2).
- Ctrl-C or TERM during a round: the running calls stop and the temporary key is deleted (test in Task 2).
- `--parallel 0`, `--max-tokens 0` or non-numeric values: refused before any key or call exists (test in Task 2).
- `--max-calls` smaller than `--parallel`: the round shrinks, and the call limit is never passed (test in Task 2).

---

### Task 1: Teach the fake upstream OpenRouter's refusals

**Files:**
- Modify: `tests/fakes/upstream.py`
- Test: `tests/fakes.bats`

**Interfaces:**
- Produces: `/_mode` accepts `refusal` (`in_flight`, `weight`, `key_limit_402`, `key_limit_403`, or absent for the existing plain 402), `refuse_first` (N: refuse the first N calls) and `refuse_above_tokens` (N: refuse calls with `max_tokens` above N). `fail_after` and `status: 402` also use the chosen `refusal`.

- [ ] **Step 1: Write the failing tests in `tests/fakes.bats`**

`fake upstream sends the chosen refusal`: for each of the four names, assert status and `limit_source`: `in_flight` 402 `openrouter_in_flight_budget`, `weight` 402 `openrouter_credits` with `reason` `weight_exceeds_budget`, `key_limit_402` 402 `openrouter_key_limit`, `key_limit_403` 403 `openrouter_key_limit`.
`fake upstream refuses the first N calls`: `refuse_first` 2 gives `402 402 200 200`.
`fake upstream refuses above a token count`: `refuse_above_tokens` 100 gives 402 for `max_tokens` 200 and 200 for `max_tokens` 100.

- [ ] **Step 2: Run them to verify they fail**

Run: `tests/run.sh tests/fakes.bats`. Expected: the three new tests fail, the others pass.

- [ ] **Step 3: Implement the modes**

Bodies are copied from OpenRouter's limits page, as in `docs/provider-facts.md`. One check decides whether a call is refused, then the chosen body is sent.

- [ ] **Step 4: Run them to verify they pass**

Run: `tests/run.sh tests/fakes.bats`. Expected: all pass.

- [ ] **Step 5: Commit**

`git add tests/fakes/upstream.py tests/fakes.bats`, with the message `test: teach the fake upstream OpenRouter's refusals`.

### Task 2: Parallel rounds and honest stopping in `drain-balance.sh`

**Files:**
- Modify: `scripts/drain-balance.sh`
- Test: `tests/drain.bats`

**Interfaces:**
- Consumes: the modes from Task 1.
- Produces: `drain-balance.sh --max-usd <amount> [--max-calls N] [--max-tokens N] [--parallel N]`. Summary lines `calls_succeeded`, `cost_of_calls_usd`, `recorded_spend_usd`, `stopped: <reason>`, `last answers:`. Reasons: `refused`, `error`, `gateway-budget`, `in-flight`, `max-usd`, `max-calls`.

- [ ] **Step 1: Write the failing tests in `tests/drain.bats`**

Fake answers report 100 prompt and 1000 completion tokens, $0.0062 a call. Replace the burst test and rewrite `stops at max-usd`. Keep the confirmation test. Use `--parallel 1` unless parallelism is the point.

| Test | Arguments and fake mode | Assertions |
|---|---|---|
| default size | `--max-usd 1 --max-calls 1` | model `qwen/qwen3.8-2.4t-a95b`, `max_tokens` 8192 |
| `--max-tokens` sets the size | `--max-usd 1 --max-calls 1 --max-tokens 512` | `max_tokens` 512 |
| `--parallel` sends calls at once | `--max-usd 1 --max-calls 5 --parallel 5`, `delay_ms` 2000 | `calls_succeeded 5`, took under 8 seconds |
| default is 5 at once | `--max-usd 1 --max-calls 5`, `delay_ms` 2000 | took under 8 seconds |
| `--max-calls` shrinks the last round | `--max-usd 1 --max-calls 3 --parallel 5` | 3 upstream calls, `stopped: max-calls` |
| `--max-calls` counts refused calls | `--max-usd 1 --max-calls 3`, `refusal` `in_flight` always, `DRAIN_RETRY_WAIT=0` | 3 upstream calls, `calls_succeeded 0` |
| a round that could pass `--max-usd` does not start | `--max-usd 0.02 --max-tokens 1000` | `calls_succeeded 3`, 3 upstream calls, `stopped: max-usd` |
| too small for one call | `--max-usd 0.001` | 0 upstream calls, `stopped: max-usd`, no key left |
| halves on a limit refusal, then goes on | `--max-usd 1 --max-tokens 1024 --max-calls 6`, `refuse_above_tokens` 256 | `max_tokens` seen: 1024 512 256 256 256 256 |
| refused below the floor, plain 402 | `--max-usd 1 --max-tokens 64`, `status` 402 | sizes 64 32 16, `stopped: refused`, `calls_succeeded 0` |
| `weight_exceeds_budget` | as above, `refusal` `weight` | same |
| key limit as 402 | as above, `refusal` `key_limit_402` | same |
| key limit as 403 | as above, `refusal` `key_limit_403` | `stopped: refused`, smallest size 16 |
| mixed round | `--max-usd 1 --max-tokens 32 --parallel 5`, `fail_after` 2 | `calls_succeeded 2`, sizes 32 and 16 seen, `stopped: refused` |
| in-flight waits, does not halve | `--max-usd 1 --max-calls 3`, `refuse_first` 2, `refusal` `in_flight`, `DRAIN_RETRY_WAIT=0` | all sizes 8192, `calls_succeeded 1` |
| in-flight gives up | `--max-usd 1`, `refusal` `in_flight` always, `DRAIN_RETRY_WAIT=0` | 6 upstream calls, `stopped: in-flight` |
| a fault stops the test | `--max-usd 1`, `status` 503 | `stopped: error`, `calls_succeeded 0`, one size only |
| a connection failure is a fault | `--max-usd 1 --max-calls 3`, `delay_ms` 3000, `DRAIN_CURL_TIMEOUT=1` | `stopped: error`, `calls_succeeded 0` |
| gateway budget | `run_setup_keys BUDGET_TEAM_EXPERIMENTS=0.005`, `--max-usd 1`; restore with `run_setup_keys` | `stopped: gateway-budget`. Last in the file |
| bad numbers | `--parallel 0`; `--max-tokens 0`; `--parallel x` | status 2, 0 upstream calls, no key left |
| TERM during a round | as the existing test | no key left, and no `curl` still running after the exit |

For the connection failure test, add `--max-time` to the script's `curl`, 660 seconds by default, overridden by `DRAIN_CURL_TIMEOUT`. That is longer than LiteLLM's default request timeout of 600 seconds (to be confirmed in the v1.106.6 source while building), so a real call is not cut short.

- [ ] **Step 2: Run them to verify they fail**

Run: `tests/run.sh tests/drain.bats`. Expected: the new behaviour fails; the confirmation test passes.

- [ ] **Step 3: Implement**

Follow the spec's table. Validate the flags as whole numbers above zero with the usage message, exit 2, before any call. Read the price with `api GET /model/info` before creating the key, and `die 1` if it is missing. `classify <status> <body file>` prints `ok`, `limit`, `in-flight`, `gateway` or `fault`. Order of checks: `200`; body has `openrouter_in_flight_budget`; status `402`, or body has `openrouter_key_limit` or `openrouter_credits`; status `422` with `budget_exceeded`; otherwise `fault`. A round's decision takes the most serious answer in this order: `fault`, `gateway`, `limit`, `in-flight`, `ok`. Print one progress line per round, as `round 3: max_tokens 1024: 200 200 402 402 402, spent 0.0620`. Stop running calls in the `cleanup` function with `jobs -p`, before deleting the key. Update the header comment and the confirmation text to state the new limits.

- [ ] **Step 4: Run them to verify they pass**

Run: `tests/run.sh tests/drain.bats`. Expected: all pass.

- [ ] **Step 5: Commit**

`git add scripts/drain-balance.sh tests/drain.bats`, with the message `fix: make the drain test tell limits from faults and test crossing`.

### Task 3: Procedure, records and the `production` note

**Files:**
- Modify: `docs/test-procedures/phase-0.md`, `docs/decisions.md`, `docs/provider-facts.md`, `README.md` (the line on clients and 402)
- Modify, other repository: `~/code/production/grafana/rapidselector-alerts.md`

- [ ] **Step 1: Update the procedure**

Apply every bullet in the spec's procedure section. D1's "you should see": rounds of 200s, then smaller calls, ending in `stopped: refused` with 402 or 403 in the last answers; `stopped: error` or `stopped: in-flight` means the test did not finish, so stop and tell Claude. Report the key's usage in the dashboard. Fix the header's "step D5" to D6. New steps: B1a, C5, D6a.

- [ ] **Step 2: Update the records**

`provider-facts.md`, new dated entry under OpenRouter: `Retry-After`, `reason` and `limit_source` values, who is subject to the in-flight budget, the docs giving both 402 and 403 for a key limit. New dated entry under LiteLLM: status and message passed on, `Retry-After` dropped, 403, 429 and 503 sent three times upstream, 402 and 404 once (seen 2026-11-04, no database or `request_guard`). `decisions.md`: a dated decision for this change; findings 26, 27, 28, 29 marked settled by it, 31 moved to step C5; new finding 32: `tests/run.sh` has no guard against a host running the real stack. Spec status: approved.

- [ ] **Step 3: Update the README line**

`README.md:102` tells clients not to retry 402. Add 403 with `limit_source`, and say 402 with `openrouter_in_flight_budget` is temporary.

- [ ] **Step 4: Verify**

Run: `tests/check-prices.sh`. Expected: 11 `ok` lines. Read the procedure through once for stale references: `grep -n "burst\|D5" docs/test-procedures/phase-0.md`. Expected: D5 only as the zero data retention step.

- [ ] **Step 5: Commit**

`git add docs README.md`, with the message `docs: align the phase 0 procedure with the new drain test`.

- [ ] **Step 6: Correct the `production` note**

On branch `rapidselector-alert-note` in `~/code/production`: replace the note that budget and failure rules fire during test A with what they actually need, and point to D6a. Commit, push, and tell the owner there is one branch to merge.

### Task 4: Level 1 on `sandbox` (the owner runs it)

- [ ] **Step 1: Push the branch**

`git push -u origin drain-test-fixes`

- [ ] **Step 2: The owner runs the suite**

On `sandbox`, before B2, with no real stack up: clone, `git switch drain-test-fixes`, `tests/run.sh`. Expected: `All N test files passed.`

- [ ] **Step 3: Fix anything that fails, then merge**

The owner merges the branch to `main`, and the walkthrough starts at A1.
