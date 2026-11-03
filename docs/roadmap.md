# Roadmap

Each phase must be usable on its own. Do not start a phase until the previous one works on the Pi.

## Phases

0. **Foundation:** Compose with `gateway`, `db` and `chat`. OpenRouter as the only provider, a few allowlisted models with pinned hosts, global budget and virtual keys for `chat` and Node-RED. Verify that the budget limits actually stop calls, both at OpenRouter and in LiteLLM. Verify that models can be called through the gateway's HTTP API with a virtual key, as Node-RED and Docker apps will do.
1. **Control tower, part 1:** login, usage, balance, reconciliation and kill switch.
2. **Control tower, part 2:** arena and benchmarking with visualisation. First evaluate existing tools, such as Open WebUI's built-in arena and promptfoo, and build only what they do not cover (likely per-host speed and cost measurement and the visualisation).
3. **Programmatic use:** first real use case (log analysis) through the gateway's HTTP API, from Node-RED or a Docker app. What is sent may need cleaning of personal data first. Decide from that experience whether an asynchronous layer is needed.
4. **Later:** local inference as an additional provider, starting with very small models on the Pi or a separate box.

## Parked options

Researched on 2026-11-02 and left out for now:

- **Very small models on the Pi:** could widen the choice below 3B and show what runs locally. RAM is the main constraint, since even Ollama's smallest Gemma 4 download (`e2b`) is 4.6 GB or more. Speed on the Pi's CPU would not predict speed on better hardware. Local models would need a deliberate exception to the non-zero spend rule, and must not be timed alongside cloud models.
- **DeepInfra directly:** two of its live text models are not on OpenRouter (`Seed-1.8` and `Seed-2.0-pro`), and going direct would avoid the fee and could measure the broker's overhead. It has weaker controls for this project: API keys are described as full-access, and no balance endpoint has been found.
- **Ollama Cloud:** no longer needed for model coverage, since models like `mistral-large-4` and `muse-spark-open` are on OpenRouter. It would use Pay as you go, never a subscription, but it has no per-key limits below Enterprise, no documented API to revoke keys, and unnamed partner hosts that cannot be pinned.
- **A custom `bridge` service** for an asynchronous layer such as MQTT: only if phase 3 shows a need (`requirements.md`, programmatic access).
