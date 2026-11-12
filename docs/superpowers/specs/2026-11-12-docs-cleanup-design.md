# The docs cleanup: what is left is of use to every home

Status: draft for the owner, 2026-11-12, after the builder check. Brainstormed with the owner the same day. Project 2 of the four in the `config/` folder spec's "Next projects" (the `CLAUDE.md` cleanup and the user guide's section on upgrading single containers come after it).

## Why

The repository should be one that others want to clone (the `config/` folder spec, "Why"). `config/` took the owner's settings out of the shared files; the docs still carry the owner's history: `docs/decisions.md` is 584 lines, mostly a step-by-step log of walkthroughs on `sandbox` and of tower, a service that was dropped. That log clutters reasoning for the owner and for Claude alike, and a newcomer cannot tell what in it matters to them.

The owner's rule (2026-11-12): **most of what we write down should be of interest to others too. Home-specific history is not kept unless it is positively of use later**, and then it goes into the owner's `production` repository. Git history keeps the rest, and that is enough. **Write restrictively**, or we drown ourselves.

## Goals, non-goals and anti-goals

**Goals:**
1. Every lesson from the log that matters to any home survives, as a short general entry in `docs/decisions.md` or `docs/provider-facts.md`.
2. The step-by-step log, tower's history and the one-off procedures leave the repository.
3. Phase 0's procedure becomes `docs/test-procedures/initial-setup-walkthrough.md`: what any new home runs once to prove its limits, alerts and backups work, matching the README rather than repeating it.
4. The handoff between sessions moves into `docs/roadmap.md`, in a few lines.
5. The few home facts worth keeping are in `production`.
6. The user docs (`README.md`, `docs/user-guide.md`, `docs/onboarding.md`, `scripts/README.md`, `config/README.md`) say "the host", not `sandbox`, and no longer say `copy-config.sh` is always needed.

**Non-goals:** changing `CLAUDE.md` (project 3, the owner's decision item by item); the user guide's section on upgrading single containers (project 4); the README dry run (`docs/roadmap.md`); any change to code or behaviour; rewriting git history.

**Anti-goals:**
- A general lesson lost with the log (above all D1 and D6, which `CLAUDE.md` principle 1 points at).
- A link or reference in a remaining file, or in a script comment, that points at something deleted.
- Docs that grow: the result is shorter than today, and each entry is as short as it can be.
- The walkthrough drifting from the README: two installation guides.

## Constraints

- `CLAUDE.md` is not edited, so what it points at must still be there: "D1 and D6 in `docs/decisions.md`" (keep those labels findable), "Test results are recorded in `docs/decisions.md`", the decision on memory limits, and the folders in "Where things live" (`docs/superpowers/specs/` and `plans/` stay as folders for work in progress).
- Script and test comments name docs: `scripts/jq/status.jq` ("`docs/decisions.md` 2026-11-08"), `tests/drain-balance.sh` (`phase-0.md`), and several `docs/provider-facts.md` mentions. No test reads a docs file (checked 2026-11-12).
- Records go straight to `main` (owner, 2026-11-11), but this work goes through a branch and a PR (below). Nothing is pushed to `production` without the owner's yes.
- `docs/test-procedures/phase-0-status.md` is the live handoff until the merge: keep it current on `main` while the branch is open.

## Approaches considered

- **Keep the owner's history in `production`** (Claude's first pick): rejected by the owner. It keeps a log nobody needs.
- **An archive folder such as `docs/history/`:** rejected. Every clone still carries the log.
- **Drop the history from `main`, keeping only what is of use** (the owner's pick, refined together): chosen.

How it is carried out:
- **Straight to `main`, one file at a time:** faster, but `main` is half cleaned for a while, and the deletions are never seen in one place.
- **Chosen (Claude's recommendation, the owner's choice): a branch `docs-cleanup` and a PR,** commits in the order below, so the owner reviews everything that goes in one diff before merging.

## The design

### The test for every entry

Keep an entry if **another home would act differently knowing it**, or if code, config or `CLAUDE.md` depends on it. Then write it as a general statement, without the walkthrough's step labels except D1 and D6. Move it to `production` only if it is about this home and positively of use later. Otherwise drop it.

### `docs/decisions.md`

Written anew as a short list, going through the old file entry by entry. Kept entries keep their original date as the heading, so references by date still work. Known to keep (not a complete list): the monthly budget and the key limit as the monthly cap; D1 (the key limit stops calls only after their spend is counted: 86% past); D6 (the balance went to −$0.19); D5 (the account's allowed-provider list refused a host without zero data retention); the global budget overshooting by a few calls while team and key budgets stop within one call; LiteLLM failing closed when the database is down; no memory limits, and why; `up` always detached; LiteLLM stays as the gateway; the management key is optional; `store_prompts_in_spend_logs` false; chat on the slim image; the scripts instead of tower, in one or two lines (tower named once, as the reason the scripts exist); the `config/` folder; the restart trap (finding 45). Settled open questions go, their lesson kept where general. Open findings keep their numbers; those about this home only (19, Node-RED's DNS) move to `production` or go.

**A section "Tested in practice"** (owner, 2026-11-12, after the builder check): one line per kind of test, saying what was tested, when, and the result, so `CLAUDE.md`'s "a limit counts as working only once it has been tested in practice" and "test results are recorded in `docs/decisions.md`" stay true without editing it. From the log at least: D1, D6 and D5 (above), recorded spend and the pin confirmed for every name (D3/D4), the alerts fired (D8), ports on the LAN address after a reboot (C5), the stack fits in memory (B5), the first backups ran (E1), and the key limit's monthly reset still to be seen (1 December). It is general: evidence that the limits work, of use to anyone. New results get a line only when they add something (a new kind of test, or a different result), not one per step: the walkthrough rule "record every result" becomes "record what is of use".

Also recorded here (owner, 2026-11-12): **a spec and its plan live only until their work is merged and verified**, then they are deleted; git keeps them.

### `docs/provider-facts.md`

Stays, minus what is about `sandbox` only. Facts about Docker on the Pi that hold for any Pi 5 stay, under a general heading.

### `docs/test-procedures/`

- `phase-0.md` becomes **`initial-setup-walkthrough.md`**. The README stays the only installation guide: the walkthrough says "follow the README's section …" for installing, and adds only what the README lacks: the checks with real money (key limit, pins and recorded spend per name, a host outside the account's list, the balance drained), the alerts, the backups and, optionally, the restore. Steps for optional integrations (Prometheus and Grafana, secrets-service, backup-orchestrator) are marked optional. Expected values come from the home's own `config/` ("the teams' budgets in `config/home.env`"), not the owner's numbers. It keeps the cost ceiling and the stop rule. **It stands on its own** (owner, 2026-11-12): written so a person can follow it alone, with one line saying Claude can walk them through it. So it spells out what `phase-0.md` left to Claude, such as how to make the temporary entry for the test with a host outside the account's list, and what to do with the results (a line in "Tested in practice" when it adds something).
- **Which of phase 0's free checks it keeps** (Claude's call, after the builder check): every check that protects a principle or the host, since none is in the README's "First setup": the level 1 tests on the host before the first start (B1a); the memory fit (B5); the reboot check that ports bind only to the LAN address (C5, the only boot-time check of principle 3); a client on the LAN reaching the gateway by the host's name (C4, Node-RED as one example). This home's first real use (E3) is not a step for every home and goes.
- **The alerts** (Claude's call): this repository describes no rule set (alert rules belong to the home's own repository, README). The walkthrough says: if you have alerts on the gateway's metrics, lower a budget like this and see them fire; it points at the README's monitoring section.
- **The restore** (Claude's call): a pointer only, not new untested steps: "Restore is not yet written or tested; see the roadmap" (E2 is parked there). `docs/user-guide.md`'s restore line points at the roadmap instead of `phase-0-status.md`.
- `ops-scripts.md` and `config-folder.md` are deleted.
- `phase-0-status.md` is deleted, its handoff merged into the roadmap (below).

### `docs/roadmap.md`

- A **"Now"** section at the top, a few lines: what we are on and what is next. It is the handoff between sessions (the owner works from two machines; Claude's memory is on one).
- The walkthrough rules from `phase-0-status.md` ("One step at a time", never paste a secret, short command lines, secrets through `run-script` with redaction) wait here, in a short section, until the `CLAUDE.md` cleanup decides whether they go into "Way of working".
- Done items shrink to a line each; struck-out items and references to deleted specs go.

### `production`

Only the home facts positively of use later, in the places the owner named (its root `README.md` or `CLAUDE.md`, or `prometheus/` and `grafana/`, in their `CLAUDE.md` or `README.md`): that `sandbox` runs rapid-selector, its clone at `/home/pi/code/rapid-selector`, and the secret `rapidselector` in secrets-service, which must never be regenerated (`LITELLM_SALT_KEY`); `sandbox`'s node_exporter textfile folder must be owned by `pi`, or the cron job stops writing; the OpenRouter account's settings (allowed providers, zero data retention, no auto top-up) and the management key's expiry date. A balance or a month's spend is not a fact worth keeping. Some of this may already be in `production` (e.g. `prometheus/CLAUDE.md`'s textfile note): check first, add nothing twice.

### User docs and comments

- `sandbox` as a host name goes from `README.md`, `docs/user-guide.md`, `docs/onboarding.md`, `scripts/README.md` and `config/README.md` (e.g. `pi@sandbox` becomes `<user>@<host>`). secrets-service, backup-orchestrator and Prometheus stay where they are described as optional integrations.
- `README.md`'s line on chat titles names the role `chat-tasks`, not a model; its examples use names from `config/gateway.example.yaml`, or say "for example".
- `copy-config.sh` is described as needed only when `config/` is edited on another machine than the host (owner, 2026-11-12), in `docs/user-guide.md`, `scripts/README.md` and `docs/onboarding.md`. Editing on the host: edit, check, apply.
- Comments that point at deleted or moved docs are updated, and nothing else in the code changes. `tests/fixtures/README.md` counts as docs: its pointers to deleted `decisions.md` entries say where the figures came from instead (the owner's host, on the dates given).
- **Test data stays as it is** (Claude's call): `tests/copy-config.bats`'s `pi@sandbox` and the owner's model names in `tests/fixtures/` and `tests/smoke-args.bats` are arbitrary test strings, read by no running system; changing them would be a code change for no gain.

### The specs and plans

All of `docs/superpowers/specs/` and `docs/superpowers/plans/` are deleted, after one check: anything in the overall design (`2026-11-03-rapid-selector-overall-design.md`) or the phase 0 design that is not already in `CLAUDE.md`, `docs/requirements.md` or `docs/roadmap.md`, and still true, moves there (restrictively). This spec and its plan are deleted on `main` once the PR is merged.

### Order of commits on the branch

1. The new `decisions.md` and the trimmed `provider-facts.md` (the lessons safe before anything is deleted).
2. The walkthrough, the roadmap with "Now", the user docs and the comments.
3. The deletions: the old procedures, the status file, the specs and plans.

The `production` commit is separate, after the owner's yes. Claude's memory note that points at `phase-0-status.md` is updated after the merge.

## How we know it is done

- `git diff --stat main...docs-cleanup` touches only `docs/`, `README.md`, `config/README.md`, `scripts/README.md`, `tests/fixtures/README.md`, and comment lines in `scripts/` and `tests/` (shown with a diff filtered to non-comment lines, which must be empty).
- Every path a remaining file names exists (a grep over the repository).
- `sandbox` as the host's name and `tower` appear nowhere in the repository except `docs/decisions.md` (tower named once), the roadmap's "Now" while a walkthrough on it is under way, and the test data above. "The cloud sandbox", where code is developed, is a different thing and stays.
- The tests that run on this machine pass (`tests/ops-logic.bats`, `tests/smoke-args.bats`); no cloud run is needed, since no code changes.
- The owner has read the PR and merged it.

## Left to the builder

The wording and order of entries; which side of the test each borderline entry falls on, as long as the known keeps above are kept; the walkthrough's step labels; where in `production` each fact goes, within the places named; how the "Now" section is laid out.
