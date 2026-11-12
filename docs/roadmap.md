# Roadmap

Each phase gets its own spec, plan and build, follows the overall design (`superpowers/specs/2026-11-03-rapid-selector-overall-design.md`), and must work on its own before the next starts.

## Phases

0. **Foundation (on `sandbox`):**
   - `gateway`, `db` and `chat`; `gateway/config.yaml` (now `config/gateway.yaml`) with the first roles and `model@host` names.
   - Teams `permanent` and `experiments`, with keys for Node-RED, `chat` and a test key.
   - `rapidselector.sh` with both secret sources (`.env` and secrets-service).
   - The smoke test, the level 1 test setup (real images against a fake upstream), the README, and the level 2 and 3 test procedure.
   - LiteLLM's `/metrics` on.
   - In the `production` repository: a Prometheus target, Grafana alerts on LiteLLM's metrics, and backup jobs for Postgres and Open WebUI. Permanent use starts here, so warnings and backups are needed from the start.
   - Done when level 1 passes, and the owner has run levels 2 and 3 on `sandbox`.
1. **Operator scripts** (`superpowers/specs/2026-11-08-scripts-instead-of-tower-design.md`, `decisions.md`):
   - `status.sh` and `reconcile.sh`, with Prometheus output; the rules check that guards `restart gateway`; `scripts/README.md`, a user guide, and the cleanup of the service they replaced.
   - In the `production` repository: the cron job for the Prometheus output, Grafana's new alerts (balance, stale figures, reconciliation, management key) and the LLM dashboard.
   - Last: an onboarding to LiteLLM's admin UI and OpenRouter's dashboard, walked through together.
   - **After the merge (owner, 2026-11-07): a fresh-eyes dry run of the README.** A new claude.ai/code session that knows nothing about the project follows only the README's "First setup", as a newcomer would, in an empty cloud sandbox: a simulation, not a real setup. The fake upstream stands in for OpenRouter, the steps in OpenRouter's dashboard are walked through on paper, and `.env` is the secret source. No real account, no real secret, no money. It reports every place where it had to guess, a step was missing or a command failed; the fixes go to the README. Finding 30 is one known gap, and another: an `.env` made before a release lacks the lines added since (seen on 2026-11-07, `decisions.md`).
   - ~~**Owner, 2026-11-07: two-factor authentication on the OpenRouter account.**~~ Done 2026-11-11, by the owner during the tour (`decisions.md`, O6); the Google account the owner signs in with has it too. Whoever signs in can create or delete keys, spend the balance and change the zero data retention and provider settings, and the management key raises the stakes. To check first: how OpenRouter offers it now, and if the account signs in through Google or GitHub, the second factor belongs on that account as well.
   - ~~**Move to `webserver`.**~~ Dropped 2026-11-06: rapid-selector stays on `sandbox` (`decisions.md`).
2. **Arena and benchmarks:** Open WebUI's built-in arena and promptfoo, set up and learnt; nothing of our own is built (`CLAUDE.md`, architecture).
   - **Owner's wish, 2026-11-05:** switch on Open WebUI's arena and try promptfoo, put on hold while phase 1 is built. To settle first, against current docs: how Open WebUI's arena picks models and what each rating costs (`ENABLE_EVALUATION_ARENA_MODELS` is off today). promptfoo is a separate tool, not part of Open WebUI, and counts as an automated client: its own key in team `experiments` with a low cap, a limit on calls per run and on input size, and every run's cost flagged first.
3. **Programmatic use cases:** real uses through the gateway's HTTP API, starting with log analysis. Each use follows the rules in `requirements.md` (programmatic access) and decides for itself whether it needs an asynchronous layer.
4. **Later:** local inference as an additional provider in the gateway, starting with very small models on the Pi or a separate box.

## Parked options

Researched on 2026-11-02 and left out for now:

- **Very small models on the Pi:** could widen the choice below 3B and show what runs locally. RAM is the main constraint, since even Ollama's smallest Gemma 4 download (`e2b`) is 4.6 GB or more. Speed on the Pi's CPU would not predict speed on better hardware. Local models would need a deliberate exception to the non-zero spend rule, and must not be timed alongside cloud models.
- **DeepInfra directly:** two of its live text models are not on OpenRouter (`Seed-1.8` and `Seed-2.0-pro`), and going direct would avoid the fee and could measure the broker's overhead. It has weaker controls for this project: API keys are described as full-access, and no balance endpoint has been found.
- **Ollama Cloud:** no longer needed for model coverage, since models like `mistral-large-4` and `muse-spark-open` are on OpenRouter. It would use Pay as you go, never a subscription, but it has no per-key limits below Enterprise, no documented API to revoke keys, and unnamed partner hosts that cannot be pinned.
- **A custom `bridge` service** for an asynchronous layer such as MQTT: only if a use case shows a need (`requirements.md`, programmatic access).
- **Web search in Open WebUI** (parked 2026-11-03): useful for current information, but questions go to an outside search service, an extra model call writes each query, and fetched pages make inputs much larger and more expensive. A self-hosted SearXNG would add a container. Switched on with a few environment variables when wanted.
  - **To consider after phase 1 (owner's wish, 2026-11-04): live search with SearXNG.** After phase 1, because the scripts and Grafana then show what it costs. To settle first:
    - **Who gets it:** Open WebUI's search helps chat only. Whether Node-RED and apps can get it too, through the gateway or by calling SearXNG themselves, needs checking against current docs.
    - **Cost:** fetched pages raise input size, which `max_tokens` does not limit. Limit results per search and page size, point the query call at the cheapest allowlisted model, and measure the cost per search against the `experiments` budget.
    - **Privacy:** SearXNG is on the LAN, but queries still reach outside search engines, and fetched pages go to the model's host. Check what SearXNG logs and sends.
    - **Untrusted content:** a fetched page can carry instructions. Acceptable in chat, but not for flows that act on a model's answer without checking it.
    - **Comparisons:** keep it off in arena and benchmark runs, so that they compare models and not search results.
    - **Fit:** its memory use must be checked on the Pi, and it stays optional and off by default, as an integration.
    - **Only selected roles (owner's wish, 2026-11-08):** search on for the roles the owner picks, off for the rest. Open WebUI has a Web Search capability per model (Workspace → Models), and the gateway's roles are its models there; the capability is kept in Open WebUI's database, not in its environment (`provider-facts.md`, 2026-11-08). To check: that a role with it off cannot search at all, not just that it starts off; how it survives `ENABLE_PERSISTENT_CONFIG=False` and a restore; and that it is part of the chat backup.
- **Documents and media in chat** (owner's wish, 2026-11-08): chatting with uploaded documents, and converting media such as audio and video, for selected roles only. Today chat runs the slim image, without the local embedding model, `pandoc` or `ffmpeg` (`decisions.md`, 2026-11-06), with `BYPASS_EMBEDDING_AND_RETRIEVAL=True`. To settle first, against current docs:
  - **Only selected roles:** Open WebUI's File Upload capability per model refuses uploads for a model with it off (`provider-facts.md`, 2026-11-08); the same checks as for search above.
  - **How documents reach the model:** either the whole text in every message (the full-text mode, no embedding model, but every message pays for the whole document), or retrieval with embeddings. Embeddings through the gateway would need an embedding model on the allowlist, pinned with a price and zero data retention like any other, so a check of what OpenRouter offers; a local embedding engine would bring back the memory and the outside call that the slim image removed.
  - **Extracting text and converting media:** which formats the slim image reads on its own; anything more means the standard image again, or an extraction service such as Tika or Docling as an extra container, which must fit the Pi. Speech-to-text needs an outside engine on the slim image, and audio leaving the house needs its own decision.
  - **Cost:** documents raise input size, which `max_tokens` does not limit. A limit on file size and on what goes into each message, retrieval query generation pointed at the cheapest role or off, and the cost per document measured against the `experiments` budget.
  - **Privacy:** principle 4 holds for every file: no work data, no personal or health data, whatever the host promises.
  - **Comparisons:** off in arena and benchmark runs, like search.
- **To consider: graphify in this repository** (owner's wish, 2026-11-06). A development tool, not part of the stack: it builds a knowledge graph of the repository for Claude Code, and its hooks steer Claude to the graph instead of reading files one by one. The `production` repository already uses it. To settle first, against current docs:
  - **Which repository** is the real one, since several forks exist, and which version to pin.
  - **What it touches:** the Claude Code hooks it installs, any git post-commit hook, and which generated files are committed or listed in `.gitignore`. In `production`, its hook leaves modified files in the checkout.
  - **Cost:** code is parsed locally, but documents go through Claude for extraction, and this repository is mostly documents. Claude usage only, not OpenRouter.
  - **Benefit:** whether a repository this small gains enough to be worth the hooks.
- **The repository as code for several homes** (owner, 2026-11-11): became the `config/` folder, each home's own settings ignored by git, with examples and `scripts/copy-config.sh` (spec `docs/superpowers/specs/2026-11-11-config-folder-design.md`, plan `docs/superpowers/plans/2026-11-12-config-folder.md`, 2026-11-12).
  - **Backup:** a home's configuration in its own repository is backed up by that repository. The data (Postgres, Open WebUI) is backed up today by `production`'s backup-orchestrator, which is this home's; another home uses the README's fallback or its own jobs. The secrets, the salt key above all, stay outside both and need their own safe copy, or a backup cannot be read.
- **Restore rehearsal, phase 0's E2** (parked by the owner, 2026-11-11, `decisions.md`): restore the newest Postgres dump into a separate Compose project on `sandbox` and call it with `KEY_NODE_RED`, under $0.001. It was meant to follow a change that would have stored the models' settings in the database, encrypted with `LITELLM_SALT_KEY`; that change was dropped, the models stay in `gateway/config.yaml`, and the database holds keys, budgets and spend, nothing that depends on the salt key (`decisions.md`, 2026-11-06). So an untested restore is a smaller risk than it was. Take it up before the database holds anything that depends on the salt key (models or provider keys added through LiteLLM's admin UI or API), and in any case before a restore is relied on. The backup has no `cache/`, and the slim image needs none.
- **Automatic fallback to another model or host** for important flows: possible within the allowlist, but every fallback needs its own price and testing. Left out while models are an enhancement.
