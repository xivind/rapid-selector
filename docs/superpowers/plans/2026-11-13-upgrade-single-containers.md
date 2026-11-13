# Upgrading one container, or a few: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the user guide explains how to upgrade one service, or several, how to find the newest version, and how to go back per service.

**Architecture:** docs only. `./rapidselector.sh update` already recreates only the services whose pinned version changed; the guide says so. No script or test changes.

**Tech Stack:** Markdown; Docker Compose v2 behaviour; GitHub and Docker Hub public APIs (read only, no secret, free).

**Spec:** `docs/superpowers/specs/2026-11-13-upgrade-single-containers-design.md`

## Global Constraints

- English; match the guide's existing style: **When:**, steps, **You should see:**, **Cost:**, **If it fails:**.
- Commands the owner runs are one line each, no heredoc (`CLAUDE.md`, "Steps the owner runs").
- Facts about tools go in `docs/provider-facts.md` with a date and a source, not in the guide alone.
- Never `latest`. Open WebUI's tag keeps `-slim`. Postgres stays on major 17.
- No upgrade is done as part of this work; `docker-compose.yml` is not changed.
- Records go straight to `main` (owner, 2026-11-11), so this small docs change is committed on `main`.

## Review Focus

1. **A tag that does not exist** (typo): the guide must send the owner to `tests/check-arm64.sh` before commit, which fails on it. A missing `-slim` is not caught by it (the full image exists too), so the guide says to check the `chat` line by eye (final review, 2026-11-13).
2. **The lookup commands' output format:** GitHub's API returns minified JSON for some repositories, so a plain `grep tag_name` prints the whole release. The commands must use `grep -o` (checked 2026-11-13: Open WebUI's answer is one line).
3. **LiteLLM's newest GitHub release may lack a `litellm-database` image:** the arm64 check catches it; the guide says to pick the previous release then.
4. **A Postgres major version reached by accident:** the Postgres command filters on `17.` so it never suggests 18; the guide says why.
5. **Going back after LiteLLM or Open WebUI started on the new version:** the guide must not promise that the old line always works.

---

### Task 1: The guide section and the facts behind it

**Files:**
- Modify: `docs/user-guide.md:136-153` (the section "Update the stack's images")
- Modify: `docs/provider-facts.md` (new subsection under "## Docker on Raspberry Pi OS", after "Compose pull and images built on the host, checked 2026-11-06")

- [ ] **Step 1: Check Compose's behaviour against current docs**

Read Docker's reference for `docker compose up` (docs.docker.com) and confirm two things: `up` recreates a container only when its configuration or image changed, and a recreated dependency restarts its dependents only with `depends_on: … restart: true` (not set in `docker-compose.yml`). If either differs, stop and report before writing.

- [ ] **Step 2: Rewrite the section**

Heading: `## Update one image, or several` (no file links to the old anchor; checked with grep). Content, in order:

- **When:** a new release of LiteLLM, Open WebUI or Postgres is wanted, for example after Open WebUI's notice of a new version.
- **Find the newest version**, one line per service, each run on any machine, no secret, free:
  - Open WebUI: `curl -s https://api.github.com/repos/open-webui/open-webui/releases/latest | grep -o '"tag_name": *"[^"]*"'` → `v0.13.3` → write `ghcr.io/open-webui/open-webui:v0.13.3-slim` (keep `-slim`).
  - LiteLLM: `curl -s https://api.github.com/repos/BerriAI/litellm/releases/latest | grep -o '"tag_name": *"[^"]*"'` → `v1.109.1` → write `ghcr.io/berriai/litellm-database:v1.109.1`. If the arm64 check finds no such image, take the release before it.
  - Postgres: `curl -s "https://hub.docker.com/v2/repositories/library/postgres/tags?name=17.&page_size=100" | grep -oE '"name":"17\.[0-9]+-alpine"' | sort -uV | tail -1` → `17.12-alpine` → write `postgres:17.12-alpine`. It looks only within 17 on purpose (see "If it fails").
  - The example versions are marked as seen on 2026-11-13.
- **Release notes:** `https://github.com/open-webui/open-webui/releases`, `https://github.com/BerriAI/litellm/releases`, `https://www.postgresql.org/docs/release/<version>/` (e.g. `17.12`). Read them, and take a backup ([Back up and restore](#back-up-and-restore)).
- **Then** the existing steps, unchanged: change only the wanted version line(s) in `docker-compose.yml`, `tests/check-arm64.sh`, level 1 in the cloud sandbox, commit, push; on the host the same four commands as today (`git pull`, `./rapidselector.sh update`, `./rapidselector.sh ps`, the smoke test).
- One sentence: `update` pulls every image but only the changed versions are new, and Compose recreates only the services whose version changed; the others keep running.
- **You should see** and **Cost:** as today.
- **If it fails:** `./rapidselector.sh logs <service>`, then going back per service:
  - **Postgres, minor step** (17.11 to 17.12): put the old version line back and run `update`.
  - **Postgres, major step** (17 to 18): not a version change alone. Each major version has its own data file format, and the new one refuses to start on the old files; it needs an export and an import. Ask before trying one.
  - **LiteLLM and Open WebUI:** each changes its own database when it starts. Putting the old line back usually works for a small step, but may not once the database has changed; the way back is then the backup, and restore is not yet tested ([Back up and restore](#back-up-and-restore)).

- [ ] **Step 3: Add the facts to `docs/provider-facts.md`**

New subsection `### Finding versions and upgrading one service, checked 2026-11-13`, one bullet each, with its source:
- GitHub's `releases/latest` API gives the newest non-prerelease tag; Open WebUI's answer is minified JSON on one line, hence `grep -o`. Seen: Open WebUI `v0.13.3`, LiteLLM `v1.109.1`, and `ghcr.io/berriai/litellm-database:v1.109.1` exists.
- Docker Hub's tags API with `name=17.` lists Postgres 17 tags; newest Alpine seen `17.12-alpine`.
- Compose's recreate rule from Step 1, with the docs page as source.
- Postgres major versions do not share a data file format; upgrading needs `pg_dump`/restore or `pg_upgrade` (source: postgresql.org, "Upgrading a PostgreSQL Cluster"; check the page and cite it).

- [ ] **Step 4: Verify**

Run each of the three lookup commands; expected one tag each, as in Step 2 or newer. Run `grep -n "Update the stack" docs/ README.md scripts/ -r | grep -v superpowers`; expected: no output. Run `grep -n "#back-up-and-restore" docs/user-guide.md`; expected: the links resolve to the existing heading `## Back up and restore`.

- [ ] **Step 5: Commit**

```bash
git add docs/user-guide.md docs/provider-facts.md
git commit -m "docs: user guide, upgrading one image or several, finding versions, going back per service"
```

### Task 2: Restore rehearsal covers Open WebUI's data

**Files:**
- Modify: `docs/roadmap.md` (parked "Restore rehearsal", line 49; "Now", line 7)

- [ ] **Step 1: Extend the parked item**

Add one sentence to "Restore rehearsal": it also covers Open WebUI's data backup, which is the way back after an Open WebUI upgrade that changed its database (owner, 2026-11-13).

- [ ] **Step 2: Update "Now"**

"Next" becomes the README dry run, then benchmarking; note the upgrade section merged 2026-11-13.

- [ ] **Step 3: Commit**

```bash
git add docs/roadmap.md
git commit -m "docs: roadmap, restore rehearsal covers Open WebUI's data; Now moves on"
```

### Task 3: Clean up

- [ ] **Step 1:** once the owner has read the new section and is satisfied, delete the spec and this plan (owner, 2026-11-12) and commit: `docs: the single-image upgrade's spec and plan removed`.
