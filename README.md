# rapid-selector

A small, self-hosted gateway and lab for open-weight language models through OpenRouter, with hard cost control. It runs on a Raspberry Pi 5 on the home network and serves two uses: testing and comparing models, and permanent use from Node-RED and apps.

Everything goes through one gateway ([LiteLLM](https://docs.litellm.ai/)): only allowlisted models, each pinned to one OpenRouter host with zero data retention, budgets per team and key, and a spend log. Chat runs in [Open WebUI](https://docs.openwebui.com/). The rules behind the design are in `CLAUDE.md`; requirements, decisions and dated facts are in `docs/`.

## What runs

| Service | Container | Address | What |
|---|---|---|---|
| `gateway` | `rapidselector-gateway` | `http://<host>:4000` | OpenAI-compatible API for every client. Admin UI at `http://<host>:4000/ui`, user `admin`, password `LITELLM_UI_PASSWORD` |
| `chat` | `rapidselector-chat` | `http://<host>:4010` | Open WebUI |
| `db` | `rapidselector-db` | none (internal only) | Postgres for the gateway's keys, budgets and spend |
| `tower` | `rapidselector-tower` | `http://<host>:4020` | Control tower: cost, usage, checks and the kill switch. Login with `TOWER_PASSWORD`. `/metrics` and `/health` need no login |

Ports bind only to the host's LAN address (`RAPIDSELECTOR_LAN_ADDRESS`), never to every interface. Give the host a fixed address with a DHCP reservation on the router, or the stack will not start after an address change.

## Requirements

- A Raspberry Pi 5 (arm64) with Docker and the Compose v2 plugin (`docker compose version` works).
- `git`, `curl`, `jq` and `openssl` on the host.
- An OpenRouter account with a prepaid balance.

Containers have no memory limits (`docs/decisions.md`). On a host with little memory to spare, you may want to add your own in `docker-compose.yml`.

## First setup

Run the commands on the host, one numbered step at a time. Most secrets are generated for you, and only the OpenRouter key has to be fetched by hand.

### 1. Prepare OpenRouter

In OpenRouter's dashboard:

1. Turn **auto top-up off**.
2. Turn off prompt logging and every opt-in to data collection, and require zero data retention for the account.
3. Create an API key for the gateway with a **monthly credit limit**. $35 fits the budgets in this repository, and a lower limit needs lower budgets too (see [Teams, keys and budgets](#teams-keys-and-budgets)). The key is shown only once, so keep it at hand for step 3.
4. Create a **management key** for tower, with an expiry of **one year**, and write down the expiry date. The key is shown only once, so keep it at hand for step 3. It cannot make model calls, but it can create, change and delete keys, so it is the most sensitive secret in the system and only tower holds it. When it is close to expiring (tower warns 30 days ahead), create a new one, replace `OPENROUTER_MANAGEMENT_KEY` where the secrets live, set the new date in `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT` in `.env` if tower shows the expiry as unknown, run `./rapidselector.sh up`, and delete the old key in OpenRouter's dashboard.
5. Buy credits. The whole balance is the most you can lose, so keep it small.

### 2. Get the code and create the settings file

```bash
git clone https://github.com/xivind/rapid-selector.git
cd rapid-selector
cp .env.example .env && chmod 600 .env
hostname -I
nano .env
```

`hostname -I` prints the host's addresses. Set `RAPIDSELECTOR_LAN_ADDRESS` in `.env` to its LAN address, usually starting with `192.168.`. Addresses starting with `172.` belong to Docker. Write values without quotes, then save and exit with `Ctrl+O`, `Enter`, `Ctrl+X`.

### 3. Create the secrets

Use **option A** unless you already run the owner's `secrets-service`.

#### Option A: in `.env` (the default)

Generate everything except the OpenRouter key. This only fills empty lines, so running it again changes nothing:

```bash
set_secret() { sed -i "s|^$1=\$|$1=$2|" .env; }
set_secret POSTGRES_PASSWORD "$(openssl rand -hex 32)"
set_secret LITELLM_MASTER_KEY "sk-$(openssl rand -hex 24)"
set_secret LITELLM_SALT_KEY "$(openssl rand -hex 32)"
set_secret LITELLM_UI_PASSWORD "$(openssl rand -hex 16)"
set_secret WEBUI_SECRET_KEY "$(openssl rand -hex 32)"
set_secret KEY_CHAT "sk-$(openssl rand -hex 24)"
set_secret KEY_NODE_RED "sk-$(openssl rand -hex 24)"
set_secret KEY_SMOKE_TEST "sk-$(openssl rand -hex 24)"
set_secret TOWER_PASSWORD "$(openssl rand -hex 16)"
set_secret TOWER_SESSION_SECRET "$(openssl rand -hex 32)"
set_secret TOWER_GATEWAY_KEY "sk-$(openssl rand -hex 24)"
unset -f set_secret
```

Then add the OpenRouter inference key by hand, after `RAPIDSELECTOR_OPENROUTER_KEY=`, and the management key after `OPENROUTER_MANAGEMENT_KEY=`. If you want to set the management key's expiry date yourself, put it after `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT=` as `2027-11-06`. This setting is not a secret and may stay empty:

```bash
nano .env
```

Check the result. This prints each name and the length of its value, never the value itself:

```bash
awk -F= '/^[A-Z_]+=/ {print $1, length($2)}' .env
```

The 13 secrets must all have a length above 0: 64 for `POSTGRES_PASSWORD`, `LITELLM_SALT_KEY`, `WEBUI_SECRET_KEY` and `TOWER_SESSION_SECRET`, 51 for `LITELLM_MASTER_KEY`, `TOWER_GATEWAY_KEY` and the three `KEY_*`, 32 for `LITELLM_UI_PASSWORD` and `TOWER_PASSWORD`, and about 70 for the two OpenRouter keys. `OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT` may be 0. `SECRETS_SERVICE_TOKEN_FILE` stays empty.

**Keep a safe copy of `.env` away from the host,** for example in a password manager. It is the only copy of your secrets.

#### Option B: in secrets-service

Leave the secret lines in `.env` empty, and set these settings instead, with the full path to your home folder:

```
SECRETS_SOURCE=secrets-service
SECRETS_SERVICE_URL=http://<secrets-service host>:8002
SECRETS_SERVICE_TOKEN_FILE=/home/<user>/.config/rapidselector/secrets-service.token
```

In secrets-service's admin UI, create a client named `rapidselector` and copy its token, which is shown only once. A client token can read and overwrite every secret in the service, so it stays in a private file. Run `read` on its own: it shows nothing while it waits. Paste the token and press Enter, then run the rest:

```bash
mkdir -p ~/.config/rapidselector && chmod 700 ~/.config/rapidselector
read -rs TOKEN
```

```bash
(umask 077; printf '%s\n' "$TOKEN" > ~/.config/rapidselector/secrets-service.token)
unset TOKEN
```

Do the same with the OpenRouter inference key, and then with the management key:

```bash
read -rs ORKEY
```

```bash
read -rs MGKEY
```

Generate the other secrets into a temporary private file. Do this **only once**, because a second run followed by the upload below replaces every secret:

```bash
touch "$HOME/rapidselector-secrets.json"
chmod 600 "$HOME/rapidselector-secrets.json"
SECRET_ARGS=(
  --arg POSTGRES_PASSWORD "$(openssl rand -hex 32)"
  --arg LITELLM_MASTER_KEY "sk-$(openssl rand -hex 24)"
  --arg LITELLM_SALT_KEY "$(openssl rand -hex 32)"
  --arg LITELLM_UI_PASSWORD "$(openssl rand -hex 16)"
  --arg RAPIDSELECTOR_OPENROUTER_KEY "$ORKEY"
  --arg WEBUI_SECRET_KEY "$(openssl rand -hex 32)"
  --arg KEY_CHAT "sk-$(openssl rand -hex 24)"
  --arg KEY_NODE_RED "sk-$(openssl rand -hex 24)"
  --arg KEY_SMOKE_TEST "sk-$(openssl rand -hex 24)"
  --arg TOWER_PASSWORD "$(openssl rand -hex 16)"
  --arg TOWER_SESSION_SECRET "$(openssl rand -hex 32)"
  --arg OPENROUTER_MANAGEMENT_KEY "$MGKEY"
  --arg TOWER_GATEWAY_KEY "sk-$(openssl rand -hex 24)"
)
jq -n "${SECRET_ARGS[@]}" '{blob: $ARGS.named}' > "$HOME/rapidselector-secrets.json"
unset SECRET_ARGS ORKEY MGKEY
```

Store them as the secret `rapidselector`, and read back the names and lengths. Replace `<secrets-service host>` first:

```bash
SERVICE=http://<secrets-service host>:8002
T=~/.config/rapidselector/secrets-service.token
curl -sS -X PUT -H "Authorization: Bearer $(cat $T)" -H 'Content-Type: application/json' --data "@$HOME/rapidselector-secrets.json" "$SERVICE/secrets/rapidselector"; echo
curl -sS -H "Authorization: Bearer $(cat $T)" "$SERVICE/secrets/rapidselector" | jq -r '.blob | to_entries[] | "\(.key) \(.value | length)"'
```

Expect a line with `"status":"success"`, then 13 names with lengths above 0. Delete the temporary file only then:

```bash
rm ~/rapidselector-secrets.json
```

If the secret `rapidselector` already exists from before tower, do not run the upload again: it would replace every secret. Run `scripts/add-tower-secrets.sh` instead. It keeps every field, adds the three tower secrets it can generate, asks for the management key without showing it, and prints names and lengths.

The stored secrets are only as safe as secrets-service's own backup, which also needs its encryption key kept away from its host.

#### Either way

**`LITELLM_SALT_KEY` must never change after the first start,** or the stored provider keys become unreadable. A database backup is useless without it.

### 4. Start everything

```bash
./rapidselector.sh up
```

The containers run in the background, and you get your prompt back when they have started. The first start takes a few minutes, and a few more the first time because it builds tower's image on the host. Then check that all four report `healthy`:

```bash
./rapidselector.sh ps
```

### 5. Create the teams and keys in the gateway

```bash
./rapidselector.sh run-script scripts/setup-keys.sh
```

It prints a summary of each team and key, and creates tower's own user and key in the gateway (`TOWER_GATEWAY_KEY`). Tower's key can read models, keys, teams and spend and block or unblock keys, and cannot call a model. It is safe to run again; it resets budgets and limits to the values in the script. Until it has run, tower shows the gateway as unreachable.

### 6. Log in to tower

Open `http://<host>:4020` and log in with `TOWER_PASSWORD`. Read it without printing the whole file: `./rapidselector.sh run-script bash -c 'echo "$TOWER_PASSWORD"'`. The Cost page shows the month's spend, the balance and the kill switch at the top. The Setup page shows every setting tower can read, including how long the management key has left.

### 7. Create the Open WebUI admin account

Open `http://<host>:4010` and create the account. Only this first account can be created; sign-ups are closed after it. The model list should show 11 names. Sending a chat message costs money.

### 8. Run the smoke test

This calls real models, and costs well under $0.01:

```bash
./rapidselector.sh run-script scripts/smoke-test.sh
```

It calls each role once. Add `--all` to call every name, or `--name <name>` to call one, such as `--name gpt-oss-20b@deepinfra`. Tower can run the same test from its Cost page (**Smoke test: roles** or **all names**). It shows the worst-case cost first and runs only after you confirm.

## Everyday commands

Always go through `./rapidselector.sh`: it loads the settings and secrets, then runs `docker compose` with whatever you give it.

| Command | What it does |
|---|---|
| `./rapidselector.sh up` | Start everything in the background (or apply changes to `docker-compose.yml`) |
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

Above these, LiteLLM's global budget is $32, and the OpenRouter key's own monthly limit ($35, set in OpenRouter's dashboard) is the actual cap. Virtual keys can call only chat completions and the model list, and a request cannot change the routing: the gateway removes `extra_body`, `provider`, `models`, `route`, `transforms` and `fallbacks` from every request (`gateway/request_guard.py`).

Budgets and allowed names live in `scripts/setup-keys.sh`; change them there and run it again. The models live in `gateway/config.yaml`; after changing it, run `./rapidselector.sh restart gateway`, since `up` does not see a change inside a mounted file.

## Calling a model from Node-RED or an app

Clients call a **role**, never a specific model: `classify`, `summarise`, `code` or `chat`. The model behind a role can change without touching the client.

```bash
curl http://<host>:4000/v1/chat/completions \
  -H "Authorization: Bearer $KEY_NODE_RED" \
  -H "Content-Type: application/json" \
  -d '{"model": "classify", "max_tokens": 200, "messages": [{"role": "user", "content": "Is this event important? Door opened at 03:12."}]}'
```

`<host>` is the name of the host running the gateway. Any OpenAI-compatible client works with base URL `http://<host>:4000/v1` and the client's own key. In Node-RED, use an HTTP request node with these headers.

**Every client must:**
- use a fixed timeout, and treat a failed call as "skip this step and log it": models are an enhancement, nothing at home may depend on them;
- retry at most once, and only on a timeout or a 5xx answer;
- never retry a budget or limit error: HTTP 422 with `"type": "budget_exceeded"` from the gateway, or 402 or 403 with `limit_source` in the message, passed on from OpenRouter. One exception: 402 with `openrouter_in_flight_budget` is temporary and may be retried after a wait;
- keep `max_tokens` small and the input short. The gateway's default `max_tokens` is only a default; a client that asks for more gets more;
- never send work data, health data or other personal data, and check log input for it first.

## Open WebUI settings

Open WebUI's settings are fixed by environment variables in `docker-compose.yml` (`ENABLE_PERSISTENT_CONFIG=False`). A switch flipped in its admin panel works until the next restart and is then gone. To change a setting, change `docker-compose.yml`, commit it, and run `./rapidselector.sh up`, which recreates only `chat`.

Background calls are limited on purpose: chat titles are generated with the cheapest model (`llama-3.1-8b-instruct@deepinfra`); tags, follow-up suggestions, autocomplete, web search and image generation are off.

## Backups

With the owner's `backup-orchestrator` (in the `production` repository), the database, Open WebUI's data and tower's database are backed up nightly. Without it, on the host:

```bash
docker exec rapidselector-db pg_dump -U litellm litellm > "litellm-$(date +%F).sql"
```

```bash
docker stop rapidselector-chat
docker run --rm -v rapidselector_chatdata:/data -v "$PWD":/backup postgres:17.11-alpine tar czf "/backup/chatdata-$(date +%F).tgz" -C /data .
docker start rapidselector-chat
```

Tower's database (`tower.db`, in the volume `rapidselector_towerdata`) is a SQLite file. Tower writes a consistent copy of it to standard output while it runs:

```bash
docker exec rapidselector-tower python -m tower.backup > "tower-$(date +%F).db"
```

Keep the secrets (at least `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY` and the virtual keys) safely with the backups: without the salt key, a restored database cannot read its stored provider keys.

## Stopping all spending (kill switch)

**In tower** (`http://<host>:4020`), the kill switch is at the top of every page. Each level takes one click and one confirmation in the page.

| Level | What it does | Use it when |
|---|---|---|
| 1 | Blocks every virtual key in the gateway except tower's. Models stop answering; the gateway and tower keep running | Something is calling too much and you want it to stop now |
| 2 | Level 1, and also disables the OpenRouter inference key. Nothing can spend, even a client that gets past the gateway | You do not trust the gateway, or level 1 is not enough |

To release, type `release` in the box and press the button. Release goes one level at a time: level 2 first (which enables the OpenRouter key again), then level 1. Tower releases only what it engaged itself. A key you blocked yourself in the gateway, or an OpenRouter key you disabled yourself, stays as it is, and tower says so.

**Without tower.** Two ways that do not depend on anything else running (not even secrets-service or tower), and they keep working if tower is down:
1. In OpenRouter's dashboard, disable the gateway's inference key. This stops everything at once.
2. On the host, stop the gateway with plain Docker:
   ```bash
   docker stop rapidselector-gateway
   ```
   Start it again with `./rapidselector.sh up`.

How fast OpenRouter refuses a disabled key is not documented. It is measured in `docs/test-procedures/tower-1a.md`, and the result is recorded in `docs/decisions.md`.

## For developers

Code and tests are developed in a cloud sandbox without access to the Pi. The level 1 tests run the real images against a fake OpenRouter, cost nothing, and must not run on a host where rapid-selector is running.

- **Run the whole suite after any change:**
  ```bash
  tests/run.sh
  ```
  In the cloud sandbox, start Docker first: `dockerd > /tmp/dockerd.log 2>&1 &`.
- **Before changing an image version:** `tests/check-arm64.sh` checks that every pinned image exists for the Pi.
- **Before changing the model list:** `tests/check-prices.sh` compares each entry's price, host and tier with OpenRouter's public API. It costs nothing.
- Tower's unit tests: `cd tower && uv run pytest` (no network, no Docker).
- Anything that needs the Pi or real money is verified with the owner by following `docs/test-procedures/phase-0.md` and `docs/test-procedures/tower-1a.md`.
