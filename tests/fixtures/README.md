# Test fixtures

Saved responses for `tests/ops-logic.bats`, which runs `scripts/jq/*.jq` on them without Docker.
Key values and hashes are replaced with placeholders.

| File | Source | Shape |
|---|---|---|
| `gateway-daily-activity.json` | LiteLLM v1.106.6 `GET /user/daily/activity`, level 1, 2026-11-06 | seen live (level 1) |
| `gateway-team-info.json` | LiteLLM v1.106.6 `GET /team/info?team_id=experiments`, level 1, 2026-11-06 | seen live (level 1) |
| `gateway-global-spend.json` | LiteLLM v1.106.6 `GET /global/spend`, values chosen | as in `docs/provider-facts.md`, "The scripts' routes" |
| `openrouter-credits.json` | OpenRouter `GET /api/v1/credits`, values chosen | from the docs; the balance matched OpenRouter's dashboard on 2026-11-07 (tower, C2) |
| `openrouter-keys.json`, `openrouter-key.json` | OpenRouter `GET /api/v1/keys`, `GET /api/v1/keys/{hash}`, values chosen | from the docs; limit and usage matched the dashboard on 2026-11-07 (tower, C2) |

`tests/gateway-api.bats` saves fresh LiteLLM responses in `tests/.artifacts/gateway-api/` on every level 1 run; refresh the gateway files from there by hand, with key values replaced, when LiteLLM is upgraded.
