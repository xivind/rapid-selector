# The docs cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Leave only docs that are of use to every home: general lessons kept, the owner's step-by-step history, tower and the one-off procedures gone, phase 0's procedure turned into a general walkthrough, and the handoff moved into the roadmap.

**Architecture:** Docs only, on a branch `docs-cleanup` (worktree `.worktrees/docs-cleanup`) with a PR. Lessons are written into their new homes first, the user docs are rewritten next, and deletions come last, so nothing general is lost between commits. "Tests" here are checks run from the shell: they must report the problem before a task's change, and nothing after it.

**Tech Stack:** Markdown, git, `git grep -P`, bats 1.11.0 via `npx` for the two suites that run on this machine.

**Spec:** `docs/superpowers/specs/2026-11-12-docs-cleanup-design.md` (approved 2026-11-12). Read it first: its "test for every entry" decides every borderline case.

## Global Constraints

- **Write restrictively:** each rewritten file ends shorter than today, and each entry is as short as it can be. Ceilings, in words (`wc -w`): `docs/decisions.md` ≤ 5,000 (today 24,367); `docs/provider-facts.md` ≤ 6,861; `docs/roadmap.md` ≤ 1,820 including "Now" and the walkthrough rules; `initial-setup-walkthrough.md` ≤ 1,739.
- **`CLAUDE.md` is not edited.** What it points at must still exist: D1 and D6 in `docs/decisions.md`, test results recorded there, the decision on memory limits. Anything from the old designs that would belong in `CLAUDE.md` is not written there: it is listed in the roadmap's "Now" for the `CLAUDE.md` cleanup.
- **No code changes:** outside `docs/`, `README.md`, `config/README.md`, `scripts/README.md` and `tests/fixtures/README.md`, only comment lines change.
- **Test data stays:** `tests/copy-config.bats`, `tests/fixtures/*.json`, `tests/smoke-args.bats`.
- **Commands in docs are checked against the scripts as they are now** (each script's header and usage line), never copied from `phase-0.md`: it names `scripts/drain-balance.sh` and `tests/check-prices.sh`, which are `tests/drain-balance.sh` and `scripts/check-prices.sh` today, and `gateway/config.yaml`, which is `config/gateway.yaml`.
- **Nothing is pushed to `production`** without the owner's yes in the conversation.
- **The worktree's `.superpowers/` is ignored by git and is deleted with the worktree:** copy anything worth keeping out of it before removing the worktree.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; the PR description ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

## Review Focus

1. **A newcomer following the walkthrough meets a README section that does not exist:** every `README, "…"` the walkthrough names must be a heading in `README.md` (check C3, Task 2).
2. **A pointer from code or `CLAUDE.md` dangles:** a script comment, an error message or `CLAUDE.md` names a deleted file or a removed section (checks C1 and C3, Tasks 3 and 4).
3. **The owner's numbers left in a procedure everyone runs:** expected outputs like `8`, `24`, `11 names`, `$35`, `$34` instead of "from `config/home.env`" (check C5, Task 2).
4. **News on `main` lost at the merge:** a record made on `main` while the branch is open, dropped when `main` is merged in (Task 4, step 2).
5. **A lesson dropped because it sat in a long walkthrough entry:** each known keep from the spec is findable in the new files (check C4, Task 1).

## The checks

Kept in the scratchpad, not committed. Each prints nothing when all is well.

```bash
# C1: every repository path a tracked file names exists (paths inside URLs or longer paths skipped).
git grep -h -o -P '(?<![\w/.:~-])(docs|scripts|tests|config|gateway|chat)/[A-Za-z0-9_./-]*[A-Za-z0-9_]\.(md|sh|bats|bash|yml|yaml|json|jq|py|env)\b' \
  -- . ':!docs/superpowers' | sort -u | while read -r p; do [ -e "$p" ] || echo "missing: $p"; done

# C2: `sandbox` as a host name, and tower, outside the allowed places.
git grep -n -w -E 'sandbox|tower' -- . ':!docs/superpowers' ':!tests/copy-config.bats' ':!tests/fixtures' \
  ':!tests/smoke-args.bats' ':!docs/roadmap.md' | grep -v -i 'cloud sandbox' | grep -v -E '^docs/decisions.md:.*\btower\b'
git grep -c -w tower -- docs/decisions.md   # must print docs/decisions.md:1

# C3: every quoted section a doc names exists as a heading in the file it names.
git grep -h -o -E '(README|user guide|scripts/README\.md)[,:]? "[^"]+"' -- . ':!docs/superpowers' | sort -u |
  while IFS= read -r ref; do
    title="${ref#*\"}"; title="${title%\"}"
    case "$ref" in README*) f=README.md ;; "user guide"*) f=docs/user-guide.md ;; *) f=scripts/README.md ;; esac
    grep -q -E "^#+ .*$(printf '%s' "$title" | sed 's/[][\.*^$/]/\\&/g')" "$f" || echo "no heading \"$title\" in $f"
  done

# C4: the spec's known keeps are findable in the new decisions.md (prints the ones missing).
for k in 'D1' 'D6' 'D5' 'Tested in practice' 'monthly' 'global budget' 'database' 'memory limits' 'detached' \
  'LiteLLM stays' 'management key is optional' 'store_prompts_in_spend_logs' 'slim' 'config/' 'restart' \
  'spec and its plan'; do grep -q -F "$k" docs/decisions.md || echo "missing keep: $k"; done

# C5: the owner's numbers in the walkthrough.
grep -n -E '\b(8|24|11|12)( names|\b.*budget)|\$3[45]|\bpermanent\b.*\b8\b' docs/test-procedures/initial-setup-walkthrough.md
```

---

### Task 1: The lessons in their new homes

**Files:**
- Modify (rewrite): `docs/decisions.md`
- Modify: `docs/provider-facts.md`

**Interfaces:**
- Produces: `docs/decisions.md` with the sections `## Decided` (dated `### YYYY-MM-DD: …` entries, original dates kept), `## Tested in practice` (one line per kind of test: what, when, result), and `## Open` (open findings with their old numbers). Later tasks point at these headings and at the labels D1, D5 and D6.

- [ ] **Step 1: Run C4 and C2 on `main`'s files to see them fail.** Expected: C4 prints at least `missing keep: Tested in practice` and `missing keep: spec and its plan`; C2 prints many lines from `docs/decisions.md`.
- [ ] **Step 2: Write the new `docs/decisions.md`,** going through the old one entry by entry with the spec's test. The spec's "Known to keep" list and its "Tested in practice" list are the minimum. Findings 20–25, 30, 32–36, 38, 39, 41 and 45 stay open unless the test says otherwise; 19 (Node-RED's DNS) goes to Task 5's list for `production`. Keep a scratch list of the home facts met on the way, for Task 5. Tower is named once, in the entry on the scripts.
- [ ] **Step 3: Trim `docs/provider-facts.md`:** drop what is about `sandbox` only; "Docker on Raspberry Pi OS" keeps what holds for any Pi 5, without the host's name; references to deleted files are reworded to say what was seen, where and when.
- [ ] **Step 4: Run C4, C2 (on these two files) and `wc -w`.** Expected: C4 prints nothing; C2 prints nothing for these two files; word counts within the ceilings.
- [ ] **Step 5: Commit** `docs: decisions.md rewritten as general lessons and "Tested in practice"; provider-facts trimmed`.

### Task 2: The initial setup walkthrough

**Files:**
- Rename and rewrite: `docs/test-procedures/phase-0.md` → `docs/test-procedures/initial-setup-walkthrough.md` (`git mv` first, so history follows)
- Modify: `tests/drain-balance.sh` (comment line 5 only), `docs/user-guide.md` (the restore line, today line 161)

**Interfaces:**
- Consumes: `docs/decisions.md`'s `## Tested in practice` (Task 1), where results go.
- Produces: the file name `docs/test-procedures/initial-setup-walkthrough.md`, which the roadmap and the user docs point at.

- [ ] **Step 1: Run C5 on `phase-0.md`** (path swapped in). Expected: lines with the owner's numbers (`8`, `24`, `11 names`, `$35`).
- [ ] **Step 2: Write the walkthrough** as the spec describes: stands on its own, one line saying Claude can walk you through it; installation by pointing at README sections; the checks with real money (key limit, pins and recorded spend per name, a host outside the account's list with the temporary entry spelled out from the old `decisions.md` entry "Step D5's temporary entry" and the D5 result, the drain); the free checks B1a, B5, C5 and C4 in general form; alerts as "if you have them" (README's monitoring section); backups; the restore as a pointer to the roadmap; cost ceiling and stop rule; results go into "Tested in practice" when they add something. Optional integrations are marked optional. Expected values say where they come from in `config/`.
- [ ] **Step 3: Point `tests/drain-balance.sh`'s comment and `docs/user-guide.md`'s restore line at the new walkthrough and the roadmap.**
- [ ] **Step 4: Run C5, C3 and C2 on the walkthrough, and `wc -w`.** Expected: nothing printed; within the ceiling.
- [ ] **Step 5: Commit** `docs: phase 0's procedure becomes the initial setup walkthrough, for any home`.

### Task 3: The roadmap, the user docs and the comments

**Files:**
- Modify: `docs/roadmap.md`, `README.md`, `docs/user-guide.md`, `docs/onboarding.md`, `docs/requirements.md` (only if the old designs add something), `scripts/README.md`, `config/README.md`, `tests/fixtures/README.md`, comment lines in `scripts/` and `tests/` that C1 flags

- [ ] **Step 1: Read the overall design and the phase 0 design** (`docs/superpowers/specs/2026-11-03-*.md`) and list what is still true and in none of `CLAUDE.md`, `docs/requirements.md` or `docs/roadmap.md`. Expected: a short list, possibly empty.
- [ ] **Step 2: Rewrite `docs/roadmap.md`:** "Now" at the top (where we are, what is next, and the items for the `CLAUDE.md` cleanup from Step 1 and Global Constraints), the walkthrough rules from `phase-0-status.md`'s "How we work through a procedure" in a short section (with "record what is of use" in place of "record every result"), phases with done items in a line each, struck-out items and references to the specs gone. Step 1's list goes into `docs/requirements.md` or the roadmap.
- [ ] **Step 3: The user docs,** as the spec's "User docs and comments" says: `sandbox` out, `<user>@<host>` in `config/README.md`, chat titles through `chat-tasks` in `README.md`, examples from `config/gateway.example.yaml`, `copy-config.sh` only when editing on another machine (user guide line 3, `scripts/README.md`'s table and intro, onboarding), `tests/fixtures/README.md`'s pointers reworded.
- [ ] **Step 4: Run C1, C2 and C3 over the whole repository** (the old procedures, the status file and the specs still exist, so C1 and C2 may still flag those files only), and `wc -w docs/roadmap.md`. Expected: flags only in files Task 4 deletes; within the ceiling.
- [ ] **Step 5: Commit** `docs: the roadmap holds the handoff; user docs and comments for any home`.

### Task 4: The deletions, `main` merged in, and the PR

**Files:**
- Delete: `docs/test-procedures/ops-scripts.md`, `docs/test-procedures/config-folder.md`, `docs/test-procedures/phase-0-status.md`, every file in `docs/superpowers/specs/` and `docs/superpowers/plans/` except this plan and its spec

- [ ] **Step 1: Delete the files and commit** `docs: the one-off procedures, the status file and the old specs and plans removed`.
- [ ] **Step 2: Merge `main` into the branch.** Anything recorded on `main` since the branch began (`git log main --not docs-cleanup -- docs`) is carried by the spec's test into the roadmap's "Now" or the new `decisions.md`; for conflicts, the deletions and rewrites win. Expected: `git diff main...HEAD --stat` shows no file with news left behind.
- [ ] **Step 3: Run every check and the local tests.**
  - C1, C2 and C3: nothing printed. C2's second line: `docs/decisions.md:1`.
  - No code changed: `git diff main...HEAD -U0 -- . ':!docs' ':!*.md' | grep -E '^[+-][^+-]' | grep -v -E '^[+-]\s*#'` prints nothing.
  - `wc -w` for the four files: within the ceilings.
  - `npx --yes bats@1.11.0 tests/ops-logic.bats tests/smoke-args.bats`: all `ok`.
- [ ] **Step 4: Push and open a draft PR** "The docs cleanup: what is left is of use to every home", listing what was kept, what went, and Claude's borderline calls, so the owner can review the deletions in one place.

### Task 5: The home facts in `production` (only with the owner's yes)

**Files:**
- Modify, in `~/code/production`: the places the spec names (root `README.md` or `CLAUDE.md`, `prometheus/CLAUDE.md`, `grafana/…`), after checking what is already there

- [ ] **Step 1: Check `production` for each fact** in the spec's `production` section and Task 1's scratch list (`git grep` there). Expected: a list of facts missing, and where each goes.
- [ ] **Step 2: Show the owner the proposed lines and places,** and wait for their yes.
- [ ] **Step 3: Commit and push in `production`** with the owner's yes, `docs: rapid-selector's facts for this home`.

### After the merge (on `main`)

- [ ] Remove the worktree and the local branch (copy out of `.superpowers/` first anything worth keeping); pull `main`.
- [ ] Delete this plan and its spec (`docs: the docs cleanup's spec and plan removed, as the work is merged`); push.
- [ ] Update Claude's memory note `phase-0-walkthrough` to point at the roadmap's "Now" instead of `phase-0-status.md`.
