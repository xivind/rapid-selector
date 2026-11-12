# config/: this home's own settings

**The rule: `scripts/` is what runs, the same for everyone; `config/` is what is yours.** The two files here hold everything that differs from one home to the next, apart from the secrets. Both are ignored by git, so an update never conflicts with them. The examples beside them are in git, as a starting point.

| File | What it holds | Read by |
|---|---|---|
| `gateway.yaml` | The allowlist: roles and experiment names, each pinned to one model and host with its prices and `max_tokens`; the global budget (`litellm_settings.max_budget`); LiteLLM's other settings. LiteLLM's own format | The gateway (mounted at `/app/config.yaml`), `scripts/check-prices.sh`, `./rapidselector.sh restart gateway` |
| `home.env` | The team and key budgets, Node-RED's limits, the account's allowed providers (`ALLOWED_HOSTS`), and optionally `RAPIDSELECTOR_REMOTE_DIR` for `copy-config.sh`. `KEY=VALUE` lines, read literally | `scripts/setup-keys.sh`, `scripts/check-prices.sh`, `scripts/copy-config.sh` |
| `gateway.example.yaml`, `home.example.env` | The starting point: a small allowlist (one role, two experiment names) and modest budgets, with a comment on every setting | Only the tests, and you, once |

No secrets go here: they stay in `.env` (or secrets-service), which never leaves the host.

## Starting from the examples

```bash
cp config/gateway.example.yaml config/gateway.yaml
cp config/home.example.env config/home.env
```

Then edit both. Every script refuses to run without its file, and never falls back to an example, so a home never runs on the example's budgets by accident.

- **`chat-tasks` must stay** in `gateway.yaml`, as a role pointed at your cheapest model: Open WebUI makes its background calls (titles) with it (`docker-compose.yml`).
- **`ALLOWED_HOSTS`** must match the allowed providers in your OpenRouter account's settings.
- **The two team budgets add up to no more than `max_budget`** in `gateway.yaml`, and the key budgets fit inside their team's (`docs/user-guide.md`, "Change a budget").

`scripts/check-prices.sh --rules-only` checks both files against these rules, and against `CLAUDE.md`'s rules for every entry; `./rapidselector.sh restart gateway` and `copy-config.sh to` run it first and refuse a broken rule.

## Edit here, apply there

Edit the files on the host, or on another machine in a clone of its own and copy them to the host over SSH:

```bash
scripts/copy-config.sh to   <user>@<host>   # this machine -> the host, after the rules check
scripts/copy-config.sh from <user>@<host>   # the host -> this machine, asking before it overwrites
```

It copies exactly these two files, asks for `user@host` if not given, and `ssh` asks for the password once. After `to`, run the steps it prints on the host: `./rapidselector.sh restart gateway`, and `setup-keys.sh` if a name or a budget changed. No commit is needed: there is no history of a home's settings in git.

The folder on the host is the same place under the home directory as this clone, or `RAPIDSELECTOR_REMOTE_DIR` in `home.env`.

## For developers

The level 1 tests run against the example files: `tests/helpers.bash` sets `RAPIDSELECTOR_GATEWAY_CONFIG` and `RAPIDSELECTOR_HOME_ENV` to them, and the scripts and `docker-compose.yml` read those two variables. They exist for the tests only. A home's own entries are covered by the rules check at every copy and restart, by `check-prices.sh`'s online price check, and by the smoke test on the host.
