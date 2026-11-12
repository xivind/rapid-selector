# The `CLAUDE.md` cleanup

Status: approved by the owner on 2026-11-13, item by item in the conversation. A small change; deleted once merged and verified (`docs/decisions.md`, 2026-11-12).

## Why
After the docs cleanup, `CLAUDE.md` is out of date in places, and the owner's rules for guiding them through steps live in the roadmap, which changes often. `CLAUDE.md` changes only by the owner's decision.

## Approaches
Edit `CLAUDE.md` and `docs/roadmap.md` directly on `main`, after the owner approved the exact wording (chosen); a branch and PR would be overhead for about fifteen lines.

## The changes (as approved)
1. "Where things live": the roadmap holds "Now", phases and parked options; `decisions.md` also what was tested in practice; new rows `docs/test-procedures/`, `docs/user-guide.md`, `docs/onboarding.md`; specs and plans deleted once their work is merged and verified.
2. Principle 1: test results under "Tested in practice".
3. Repository structure: `chat/` out, `tests/` in, the `docs/` comment updated.
4. Decisions: only what is of use to any home; a home's own facts go to its own repository.
5. Development: on a machine without Docker, and in a cloud sandbox (amd64) for the Docker runs.
6. The roadmap's walkthrough rules: the money rule joins the money bullet; the host-change rule joins "Surgical changes"; pushback is already in "Think before coding"; "record every result" is replaced by 4; the rest becomes a group "Steps the owner runs" (three bullets) in "Way of working".
7. The roadmap loses "How we walk through a procedure" and the "Now" bullet for this cleanup; "Now" moves to the user guide's upgrade section.

Not changed (owner): principle 3's "No remote login", and "The owner has not used Compose before".

## Done when
The seven changes are in; every path `CLAUDE.md` names exists; the roadmap no longer holds the rules; nothing else in `CLAUDE.md` changed.
