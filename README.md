# rapid-selector

A small, self-hosted gateway and lab for open-weight language models through OpenRouter, with hard cost control. It runs on a Raspberry Pi 5 on the home network and serves two uses: testing and comparing models, and permanent use from Node-RED and apps.

Everything goes through one gateway ([LiteLLM](https://docs.litellm.ai/)): only allowlisted models, each pinned to one OpenRouter host with zero data retention, budgets per team and key, and a spend log. Chat runs in [Open WebUI](https://docs.openwebui.com/). The rules behind the design are in `CLAUDE.md`; requirements, decisions and dated facts are in `docs/`.

## What runs

| Service | Container | Address | What |
|---|---|---|---|
| `gateway` | `rapidselector-gateway` | `http://<host>:4000` | OpenAI-compatible API for every client. Admin UI at `http://<host>:4000/ui`, user `admin`, password `LITELLM_UI_PASSWORD` |
| `chat` | `rapidselector-chat` | `http://<host>:4010` | Open WebUI |
| `db` | `rapidselector-db` | none (internal only) | Postgres for the gateway's keys, budgets and spend |
| `tower` | | `http://<host>:4020` | Reserved for the control tower (phase 1) |

Ports bind only to the host's LAN address (`RAPIDSELECTOR_LAN_ADDRESS`), never to every interface. Give the host a fixed address with a DHCP reservation on the router, or the stack will not start after an address change.

## Requirements

- A Raspberry Pi 5 (arm64) with Docker and the Compose v2 plugin (`docker compose version` works).
- `curl`, `jq` and `openssl` on the host.
- An OpenRouter account with a prepaid balance and **auto top-up off**.

## First setup

1. **Clone the repository** on the host and go into it.
2. **Create `.env`** from the example and fill in the settings at the top:
   ```bash
   cp .env.example .env
   ```
   Write values without quotes.
3. **Generate the secrets.** Each secret in `.env.example` has a comment with the command that makes it, for example `openssl rand -hex 32` or `echo "sk-$(openssl rand -hex 24)"` for the virtual keys. The OpenRouter key comes from OpenRouter's dashboard.
   - With `SECRETS_SOURCE=env`, put them in `.env`.
   - With `SECRETS_SOURCE=secrets-service`, store them as fields of one secret named `rapidselector` in secrets-service, set `SECRETS_SERVICE_URL`, and point `SECRETS_SERVICE_TOKEN_FILE` at a file holding the client token. Leave the secrets in `.env` empty.
   - **Keep a safe copy of the secrets.** `LITELLM_SALT_KEY` must never change after the first start, or the stored provider keys become unreadable. A database backup is useless without it.
4. **Start everything:**
   ```bash
   ./rapidselector.sh up -d
   ```
   The first start takes a few minutes. Check that all three report `healthy`:
   ```bash
   ./rapidselector.sh ps
   ```
5. **Create the teams and keys** in the gateway:
   ```bash
   ./rapidselector.sh run-script scripts/setup-keys.sh
   ```
   It prints a summary of each team and key. It is safe to run again; it resets budgets and limits to the values in the script.
6. **Create the Open WebUI admin account** at `http://<host>:4010`. Only this first account can be created; sign-ups are closed after it.
7. **Run the smoke test** (costs well under $0.01):
   ```bash
   ./rapidselector.sh run-script scripts/smoke-test.sh
   ```

## Everyday commands

Always go through `./rapidselector.sh`: it loads the settings and secrets, then runs `docker compose` with whatever you give it.

| Command | What it does |
|---|---|
| `./rapidselector.sh up -d` | Start everything (or apply changes to `docker-compose.yml`) |
| `./rapidselector.sh down` | Stop and remove the containers. Data in the volumes is kept |
| `./rapidselector.sh logs -f` | Follow the logs (Ctrl-C to stop following). Add a service name, e.g. `logs -f gateway` |
| `./rapidselector.sh ps` | Show the containers and their health |
| `./rapidselector.sh update` | Pull the image versions in `docker-compose.yml` and recreate what changed |
| `./rapidselector.sh run-script <script>` | Run one of the scripts in `scripts/` with the secrets loaded |

**Updating** means changing an image version in `docker-compose.yml` (in a commit), then on the host `git pull` and `./rapidselector.sh update`. Before upgrading LiteLLM or Open WebUI: read the release notes, take a backup, and run the smoke test afterwards.

## Teams, keys and budgets

All limits are in USD and reset on the 1st of the month at 00:00 UTC.

| Team or key | Budget | May use |
|---|---|---|
| Team `permanent` | $8 | The roles only |
| Key `node-red` (`KEY_NODE_RED`) | $4, about 30 calls and 100,000 tokens a minute | The roles only |
| Team `experiments` | $24 | Every name |
| Key `chat` (`KEY_CHAT`, used by Open WebUI) | the team's | Every name |
| Key `smoke-test` (`KEY_SMOKE_TEST`) | $1 | Every name |

Above these, LiteLLM's global budget is $32, and the OpenRouter key's own monthly limit ($34, set in OpenRouter's dashboard) is the actual cap. Virtual keys can call only chat completions and the model list, and a request cannot change the routing: the gateway removes `extra_body`, `provider`, `models`, `route`, `transforms` and `fallbacks` from every request (`gateway/request_guard.py`).

Budgets and allowed names live in `scripts/setup-keys.sh`; change them there and run it again. The models live in `gateway/config.yaml`.

## Calling a model from Node-RED or an app

Clients call a **role**, never a specific model: `classify`, `summarise`, `code` or `chat`. The model behind a role can change without touching the client.

```bash
curl http://llm:4000/v1/chat/completions \
  -H "Authorization: Bearer $KEY_NODE_RED" \
  -H "Content-Type: application/json" \
  -d '{"model": "classify", "max_tokens": 200, "messages": [{"role": "user", "content": "Is this event important? Door opened at 03:12."}]}'
```

`llm` is a name on the router pointing to the current host. Any OpenAI-compatible client works with base URL `http://llm:4000/v1` and the client's own key. In Node-RED, use an HTTP request node with these headers.

**Every client must:**
- use a fixed timeout, and treat a failed call as "skip this step and log it": models are an enhancement, nothing at home may depend on them;
- retry at most once, and only on a timeout or a 5xx answer;
- never retry a budget or limit error: HTTP 422 with `"type": "budget_exceeded"` from the gateway, or 402 passed on from OpenRouter;
- keep `max_tokens` small and the input short. The gateway's default `max_tokens` is only a default; a client that asks for more gets more;
- never send work data, health data or other personal data, and check log input for it first.

## Open WebUI settings

Open WebUI's settings are fixed by environment variables in `docker-compose.yml` (`ENABLE_PERSISTENT_CONFIG=False`). A switch flipped in its admin panel works until the next restart and is then gone. To change a setting, change `docker-compose.yml`, commit it, and run `./rapidselector.sh up -d`, which recreates only `chat`.

Background calls are limited on purpose: chat titles are generated with the cheapest model (`llama-3.1-8b-instruct@deepinfra`); tags, follow-up suggestions, autocomplete, web search and image generation are off.

## Backups

With the owner's `backup-orchestrator` (in the `production` repository), the database and Open WebUI's data are backed up nightly. Without it, on the host:

```bash
docker exec rapidselector-db pg_dump -U litellm litellm > "litellm-$(date +%F).sql"
```

```bash
docker stop rapidselector-chat
docker run --rm -v rapidselector_chatdata:/data -v "$PWD":/backup postgres:17.11-alpine tar czf "/backup/chatdata-$(date +%F).tgz" -C /data .
docker start rapidselector-chat
```

Keep the secrets (at least `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY` and the virtual keys) safely with the backups: without the salt key, a restored database cannot read its stored provider keys.

## Stopping all spending (manual kill switch)

Two ways that do not depend on anything else running (not even secrets-service):
1. In OpenRouter's dashboard, disable the gateway's inference key. This stops everything at once.
2. On the host, stop the gateway with plain Docker:
   ```bash
   docker stop rapidselector-gateway
   ```
   Start it again with `./rapidselector.sh up -d`.

## For developers

Code and tests are developed in a cloud sandbox without access to the Pi. The level 1 tests run the real images against a fake OpenRouter, cost nothing, and must not run on a host where rapid-selector is running.

- **Run the whole suite after any change:**
  ```bash
  tests/run.sh
  ```
  In the cloud sandbox, start Docker first: `dockerd > /tmp/dockerd.log 2>&1 &`.
- **Before changing an image version:** `tests/check-arm64.sh` checks that every pinned image exists for the Pi.
- **Before changing the model list:** `tests/check-prices.sh` compares each entry's price, host and tier with OpenRouter's public API. It costs nothing.
- Anything that needs the Pi or real money is verified with the owner by following `docs/test-procedures/phase-0.md`.
