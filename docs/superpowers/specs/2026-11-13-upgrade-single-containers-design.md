# Upgrading one container, or a few: design

A small change, docs only.

## Intent

The owner wants to upgrade one service at a time, as when Open WebUI says a new version is out, without recreating the others. Today's guide section, "Update the stack's images" (`docs/user-guide.md`), reads as if the whole stack is updated at once, and its "If it fails" line assumes going back is always just the old version line.

## What is already true

All images are pinned to exact versions. Changing one version line and running `./rapidselector.sh update` pulls nothing new for the other images, and Compose recreates only the changed service. So the existing command already does a single-service upgrade; the guide does not say so.

## Approaches

- **Docs only (chosen by the owner):** explain that `update` recreates only what changed, and how to go back per service.
- **Make `update <service>` work:** today it becomes `docker compose <service> pull`, an error. Not needed, since `update` with no name already does the job; it would add code and a test for no gain.

## The change

1. Reword "Update the stack's images" so it covers one service or several: only the services whose version line changed are recreated. Open WebUI's tag keeps its `-slim` ending.
2. How to find the newest version: one command per service, or the page to look at, run on any machine, no secret, free. For Open WebUI: `curl -s https://api.github.com/repos/open-webui/open-webui/releases/latest | grep -o '"tag_name": *"[^"]*"'`. `tests/check-arm64.sh` catches a tag that does not exist. (Claude's addition, 2026-11-13, after the owner asked for the command.)
3. Replace "If it fails" with how to go back, per service:
   - **Postgres:** a minor step (17.11 to 17.12) is just the old version line again. A major step (17 to 18) needs an export and import, because each major version has its own data file format; Postgres 18 refuses to start on 17's files.
   - **LiteLLM and Open WebUI:** each changes its database when it starts, so the old image may not work afterwards; the way back is then the backup, and restore is untested.
4. Roadmap, parked "Restore rehearsal": add Open WebUI's data, which it does not cover today.

## Non-goals

No change to `rapidselector.sh` or the tests. No upgrade is done as part of this work.
