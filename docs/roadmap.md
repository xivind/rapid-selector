# Roadmap

Where we are, the phases, and options parked for later. Each piece of work gets a spec and a plan, which are deleted once it is merged and verified.

## Now

- **On:** the docs cleanup, on the branch `docs-cleanup` (PR for the owner's review). Then, in order: the `CLAUDE.md` cleanup, the user guide's section on upgrading one or more containers, the README dry run (phase 1 below), and benchmarking (phase 2).
- **For the `CLAUDE.md` cleanup**, item by item with the owner: the walkthrough rules below, whether they go into "Way of working"; "Where things live" (the roadmap's "Now", specs and plans deleted after their work, `docs/test-procedures/`); `docs/decisions.md`'s "Tested in practice" as where test results go.
- **The owner's host, `sandbox`,** runs the real stack: never run level 1 there. Its own facts are in the owner's `production` repository. Still open there: the first real use from Node-RED.

## How we walk through a procedure

The owner's instructions, on top of `CLAUDE.md`, until the `CLAUDE.md` cleanup decides where they go:

- One step at a time: what to run or click, what to see, what it costs. **Wait for the report before the next step.** Record what is of use (`docs/decisions.md`, "Tested in practice"), and commit and push it.
- **Stop and ask before anything that spends money beyond the procedure's stated cost.**
- **The owner never pastes a secret value to Claude.** Names and statuses only. Secrets go through `./rapidselector.sh run-script bash -c '…'`, with the header on stdin (`curl -H @-`), and output that could hold a key through `sed -E "s/sk-[A-Za-z0-9_-]+/sk-REDACTED/g"`.
- Plain language and complete commands, saying what each output should look like; the owner is new to Compose.
- The owner welcomes pushback and pushes back too: ask whether something is needed before proposing a change to a host.
- **Pasting is fragile on the owner's terminal:** short command lines, never a heredoc or indented code to paste; anything longer goes in a committed script the owner pulls. A silent `read -rs` line runs on its own.

## Phases

0. **Foundation,** done 2026-11-06: `gateway`, `db` and `chat`; teams `permanent` and `experiments` with their keys; `rapidselector.sh` with both secret sources; the smoke test, the level 1 tests and the README; the initial setup walkthrough (`docs/test-procedures/initial-setup-walkthrough.md`); metrics, alerts and backups as optional integrations.
1. **Operator scripts,** done 2026-11-11: `status.sh`, `reconcile.sh`, the rules check that guards `restart gateway`, Prometheus output, `scripts/README.md`, the user guide and the onboarding tour; then the `config/` folder (2026-11-12). Still to do:
   - **A fresh-eyes dry run of the README** (owner, 2026-11-07). A new claude.ai/code session that knows nothing about the project follows only the README's "First setup", as a newcomer would, in an empty cloud sandbox: a simulation, not a real setup. The fake upstream stands in for OpenRouter, the steps in OpenRouter's dashboard are walked through on paper, and `.env` is the secret source. No real account, no real secret, no money. It reports every place where it had to guess, a step was missing or a command failed; the fixes go to the README. Known gaps: finding 30, and an `.env` made before a release lacks the lines added since.
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
- **Restore rehearsal** (parked by the owner, 2026-11-11): restore the newest Postgres dump into a separate Compose project on the host and call it with `KEY_NODE_RED`, under $0.001. The database holds keys, budgets and spend, nothing that depends on `LITELLM_SALT_KEY`, as the models stay in `config/gateway.yaml`, so an untested restore is a limited risk. Take it up before the database holds anything that depends on the salt key (models or provider keys added through LiteLLM's admin UI or API), and in any case before a restore is relied on. The backup has no `cache/`, and the slim image needs none.
- **Automatic fallback to another model or host** for important flows: possible within the allowlist, but every fallback needs its own price and testing. Left out while models are an enhancement.
