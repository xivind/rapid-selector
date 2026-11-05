# Roadmap

Each phase gets its own spec, plan and build, follows the overall design (`superpowers/specs/2026-11-03-rapid-selector-overall-design.md`), and must work on its own before the next starts.

## Phases

0. **Foundation (on `sandbox`):**
   - `gateway`, `db` and `chat`; `gateway/config.yaml` with the first roles and `model@host` names.
   - Teams `permanent` and `experiments`, with keys for Node-RED, `chat` and a test key.
   - `rapidselector.sh` with both secret sources (`.env` and secrets-service).
   - The smoke test, the level 1 test setup (real images against a fake upstream), the README, and the level 2 and 3 test procedure.
   - LiteLLM's `/metrics` on.
   - In the `production` repository: a Prometheus target, Grafana alerts on LiteLLM's metrics, and backup jobs for Postgres and Open WebUI. Permanent use starts here, so warnings and backups are needed from the start.
   - Done when level 1 passes, and the owner has run levels 2 and 3 on `sandbox`.
1. **Tower, part 1:**
   - **First, with the owner:** the level of visual ambition and the stack.
   - Login, cost summary, OpenRouter balance and key limit, reconciliation, kill switch at both levels, `/metrics`.
   - In the `production` repository: a backup job for tower's SQLite, the Grafana dashboard, and the remaining alerts.
   - **Move to `webserver`:** a separate step following the move procedure, when things are stable. Suggested after phase 1; the owner decides when.
2. **Arena and benchmarks:** first evaluate Open WebUI's built-in arena and promptfoo, and build in tower only what they do not cover (likely per-host speed and cost comparison, and the visualisation).
   - **Owner's wish, 2026-11-05:** switch on Open WebUI's arena and try promptfoo, put on hold while tower part 1 is designed. To settle first, against current docs: how Open WebUI's arena picks models and what each rating costs (`ENABLE_EVALUATION_ARENA_MODELS` is off today). promptfoo is a separate tool, not part of Open WebUI, and counts as an automated client: its own key in team `experiments` with a low cap, a limit on calls per run and on input size, and every run's cost flagged first.
3. **Programmatic use cases:** real uses through the gateway's HTTP API, starting with log analysis. Each use follows the rules in `requirements.md` (programmatic access) and decides for itself whether it needs an asynchronous layer.
4. **Later:** local inference as an additional provider in the gateway, starting with very small models on the Pi or a separate box.

## Parked options

Researched on 2026-11-02 and left out for now:

- **Very small models on the Pi:** could widen the choice below 3B and show what runs locally. RAM is the main constraint, since even Ollama's smallest Gemma 4 download (`e2b`) is 4.6 GB or more. Speed on the Pi's CPU would not predict speed on better hardware. Local models would need a deliberate exception to the non-zero spend rule, and must not be timed alongside cloud models.
- **DeepInfra directly:** two of its live text models are not on OpenRouter (`Seed-1.8` and `Seed-2.0-pro`), and going direct would avoid the fee and could measure the broker's overhead. It has weaker controls for this project: API keys are described as full-access, and no balance endpoint has been found.
- **Ollama Cloud:** no longer needed for model coverage, since models like `mistral-large-4` and `muse-spark-open` are on OpenRouter. It would use Pay as you go, never a subscription, but it has no per-key limits below Enterprise, no documented API to revoke keys, and unnamed partner hosts that cannot be pinned.
- **A custom `bridge` service** for an asynchronous layer such as MQTT: only if a use case shows a need (`requirements.md`, programmatic access).
- **Web search in Open WebUI** (parked 2026-11-03): useful for current information, but questions go to an outside search service, an extra model call writes each query, and fetched pages make inputs much larger and more expensive. A self-hosted SearXNG would add a container. Switched on with a few environment variables when wanted.
  - **To consider after phase 1 (owner's wish, 2026-11-04): live search with SearXNG.** After phase 1, because tower then shows what it costs. To settle first:
    - **Who gets it:** Open WebUI's search helps chat only. Whether Node-RED and apps can get it too, through the gateway or by calling SearXNG themselves, needs checking against current docs.
    - **Cost:** fetched pages raise input size, which `max_tokens` does not limit. Limit results per search and page size, point the query call at the cheapest allowlisted model, and measure the cost per search against the `experiments` budget.
    - **Privacy:** SearXNG is on the LAN, but queries still reach outside search engines, and fetched pages go to the model's host. Check what SearXNG logs and sends.
    - **Untrusted content:** a fetched page can carry instructions. Acceptable in chat, but not for flows that act on a model's answer without checking it.
    - **Comparisons:** keep it off in arena and benchmark runs, so that they compare models and not search results.
    - **Fit:** its memory use must be checked on the Pi, and it stays optional and off by default, as an integration.
- **Automatic fallback to another model or host** for important flows: possible within the allowlist, but every fallback needs its own price and testing. Left out while models are an enhancement.
