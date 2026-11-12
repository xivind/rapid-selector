# The `CLAUDE.md` cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `CLAUDE.md` up to date and move the owner's step rules into it, as approved item by item.

**Architecture:** One task: edit `CLAUDE.md` and `docs/roadmap.md` on `main`, checked by greps that fail before and pass after.

**Tech Stack:** Markdown, git.

**Spec:** `docs/superpowers/specs/2026-11-13-claude-md-cleanup-design.md`

## Global Constraints
- The wording is the owner's approved text in the conversation of 2026-11-13; nothing else in `CLAUDE.md` changes.
- Principle 3's "No remote login" and "The owner has not used Compose before" stay as they are.

## Review Focus
1. A path `CLAUDE.md` names that does not exist (check K1).
2. A rule lost on the way from the roadmap to `CLAUDE.md` (check K2).

---

### Task 1: The edits

**Files:** Modify `CLAUDE.md`, `docs/roadmap.md`

- [ ] **Step 1: Run the checks and see them fail.**
  - K1: every `docs/…`, `scripts/…`, `tests/…`, `config/…` path in `CLAUDE.md` exists, and no `chat/` line remains. Expected before: the `chat/` line.
  - K2: `CLAUDE.md` contains "Tested in practice", "Steps the owner runs", "sk-REDACTED", "read -rs", "on hosts", "stated cost", "docs/test-procedures/", "docs/user-guide.md", "docs/onboarding.md", "tests/", "of use to any home", "without Docker"; the roadmap no longer contains "How we walk through a procedure" or "For the `CLAUDE.md` cleanup". Expected before: all missing or present the wrong way.
- [ ] **Step 2: Make the seven changes** from the spec, with the approved wording.
- [ ] **Step 3: Run K1 and K2.** Expected: nothing printed. `git diff --stat` shows only `CLAUDE.md` and `docs/roadmap.md`.
- [ ] **Step 4: Commit and push** `docs: CLAUDE.md cleanup, approved by the owner item by item`; then delete this plan and its spec (`docs: the CLAUDE.md cleanup's spec and plan removed`), and push.
