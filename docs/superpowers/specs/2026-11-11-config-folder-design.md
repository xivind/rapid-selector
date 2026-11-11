# A `config/` folder for each home's own settings

Status: draft for the owner, 2026-11-11, after the builder check. Brainstormed with the owner the same day.

## Why

The repository should be one that others want to clone: a clean starting point, not one person's setup. Today a clone gets the owner's allowlist, budgets and allowed providers, built into files everyone shares (`gateway/config.yaml`, `scripts/setup-keys.sh`, `scripts/check-prices.sh`), and the tests count the owner's 11 names. That looks unprofessional and would make every update conflict for a second user. Privacy is not the reason: the owner does not mind others seeing which models, budgets and providers they use.

The history of the owner's own settings does not matter ("running changes", protected by the tests and the rules check). What matters is that the owner keeps the way of working they have now: Claude edits on this machine, and the change reaches `sandbox` with one short step.

## Goals, non-goals and anti-goals

**Goals:**
1. Every home-specific setting that changes over time lives in `config/`, in files git ignores. The repository ships example files beside them.
2. One rule, easy to remember: **`scripts/` is what runs, the same for everyone; `config/` is what is yours.** `.env` stays as it is: it belongs to the host and holds the secrets.
3. `scripts/copy-config.sh` copies the home's files from this machine to the host (`to`), or from the host to this machine (`from`), so a second machine (the owner's other Chromebook) can start by fetching the current state.
4. A clone passes the level 1 suite without any home of its own: the tests use the example files.
5. Moving `sandbox` to the new layout is a short written procedure, with no downtime beyond one gateway restart.

**Non-goals:** keeping a history of a home's settings; moving `.env` (it stays where it is and is never copied); the docs cleanup and the `CLAUDE.md` cleanup (the next two projects, below); restarting the gateway or running scripts on the host from the copy script; a way to template or generate the gateway's config.

**Anti-goals:**
- A copy that sends a broken config to the host.
- A missing `config/` file silently replaced by an example (the example's budgets applied to a real home).
- Secrets in `config/`, or a copy that moves them.
- A copy script that grows into a deployment tool.

## Constraints

`CLAUDE.md` and the walkthrough rules in `docs/test-procedures/phase-0-status.md`, in particular: short command lines for the owner; the owner never pastes a secret; `LITELLM_SALT_KEY` and the secret `rapidselector` must not change; anything on `sandbox` is the owner's step, following a written procedure; the real stack runs on `sandbox`, so level 1 never runs there. Every principle-1 rule still holds for whatever is in `config/gateway.yaml`, and `./rapidselector.sh restart gateway` still refuses a config that breaks one.

## Approaches considered

- **Leave it as it is:** rejected. It is the problem.
- **The owner's files in `production`:** rejected. Other homes have no `production`, and the transport would depend on one home's repository.
- **`home/` as its own private git repository, nested and ignored:** workable, but two repositories to pull on `sandbox`, and a second repository to look after. The owner found it messy.
- **The owner's files on a separate branch, checked out into the folder as a git worktree:** one repository, but the branch shows on GitHub and comes with every clone, and a worktree is one more git concept on `sandbox`.
- **A loader script holding the config, committed, and reset each night by a GitHub Action** (the owner's first idea): rejected. The config is then in `main`'s history anyway, a clone during the day gets it, and a nightly bot commit to `main` is a lot of machinery for nothing hidden.
- **Editing the files by hand on `sandbox`, like `.env`:** rejected. Claude could no longer make the change, and pasting indented YAML is fragile on the owner's terminal.
- **Chosen (the owner's design, refined together): `config/` with examples in git and the home's own files ignored, plus a committed copy script over SSH** that the owner runs with the host and the SSH password. One repository, no history needed, and the same edit-here, apply-there habit. SSH from both of the owner's Chromebooks to `sandbox` works (owner).

## The design

### Layout

```
rapid-selector/
├── scripts/                  what runs: the same for everyone
│   ├── status.sh, reconcile.sh, setup-keys.sh, check-prices.sh, …
│   └── copy-config.sh        new: copies config/ to the host, or from it
├── config/                   what is yours
│   ├── README.md             what each file is, which script reads it, how to copy it
│   ├── gateway.example.yaml  in git: the starting point
│   ├── home.example.env      in git: the starting point
│   ├── gateway.yaml          ignored by git: this home's allowlist (was gateway/config.yaml)
│   └── home.env              ignored by git: this home's budgets, limits and providers
├── gateway/                  request_guard.py only
└── .env                      unchanged: the host's settings and the secrets, never copied
```

`.gitignore` names `config/gateway.yaml` and `config/home.env`. (The owner chose to keep the copy script in `scripts/`, for the one rule, and to keep `.env` out of `config/`, so a copy can never carry a secret.)

### What moves into `config/`

- **`config/gateway.yaml`:** everything `gateway/config.yaml` holds today, unchanged in format (LiteLLM's own): the allowlist with prices and hosts, roles and experiment names, `max_tokens`, the global budget (`litellm_settings.max_budget`) and the general settings. Plus one new role, below.
- **A new role `chat-tasks`** (owner, 2026-11-11) for Open WebUI's own background calls. Today `docker-compose.yml` names one of the owner's models (`TASK_MODEL_EXTERNAL: llama-3.1-8b-instruct@deepinfra`), so a clone would point it at a model it lacks. Compose names the role instead, `TASK_MODEL_EXTERNAL: chat-tasks`, the same for every home, and each home's `gateway.yaml` points the role at its cheapest model (`CLAUDE.md`, "clients call roles" and "hidden usage"). In the owner's config it points at the same model and host as `llama-3.1-8b-instruct@deepinfra` today, so title calls cost the same. Only title generation is on today; if tags or follow-ups are switched on later, they use the same role, hence the broader name. Like every role it goes to team `permanent` too, so Node-RED may call it (harmless: the cheapest model). The name `extract` was considered and left free for a future role that extracts structure from text.
- **`config/home.env`**, `KEY=VALUE` lines read literally by `lib.sh`'s existing `load_env_file` (no shell evaluation):
  - the budgets now at the top of `scripts/setup-keys.sh`: `BUDGET_TEAM_PERMANENT`, `BUDGET_TEAM_EXPERIMENTS`, `BUDGET_KEY_NODE_RED`, `BUDGET_KEY_SMOKE_TEST`;
  - Node-RED's limits: `NODE_RED_RPM`, `NODE_RED_TPM`;
  - the account's allowed providers, now `ALLOWED_HOSTS` in `scripts/check-prices.sh`;
  - optionally `RAPIDSELECTOR_REMOTE_DIR`, the clone's folder on the host (see the copy script).

  The scripts lose these values and read them from `config/home.env`. The owner's file holds exactly today's values, so nothing changes in behaviour.
- **Not moved** (Claude's call, agreed by the owner): `status.jq`'s warning thresholds (balance below $10, a budget 80% spent, the management key within 30 days). They follow OpenRouter's behaviour and the scripts' purpose, not a home: the $10 is where OpenRouter's extra billing checks start ("single digit dollars", `provider-facts.md`).

### The examples

- **`config/gateway.example.yaml`:** 3 entries (Claude's call, accepted by the owner): one role and two experiment names, on at least two different allowed providers, with real prices and hosts as checked on the day it is written, and the same general settings and rules as the owner's config. A small example, so a clone does not start from the owner's setup.
- **`config/home.example.env`:** every name above, with modest example budgets that keep the order of limits (team budgets add up to at most the global budget in the example `gateway.yaml`), and a comment per line.

### Checking `home.env`

New (owner, 2026-11-11): the rules check that `./rapidselector.sh restart gateway` and `copy-config.sh to` already run also checks `config/home.env`: every name present, each budget and limit a positive number, each provider in the list a plain tag, and **the team budgets adding up to no more than the global budget** (`litellm_settings.max_budget` in `gateway.yaml`), the rule in `CLAUDE.md` principle 1 that nothing enforces today. It refuses the same way a broken `gateway.yaml` is refused (restart: exit 5; copy: exit 1), naming the setting. Test first, one test per rule. Where the check lives (`check-prices.sh --rules-only`, or a function it calls) is the builder's call.

### How the scripts find `config/`

- Fixed paths, `config/gateway.yaml` and `config/home.env`, under the repository. Compose mounts `./config/gateway.yaml`.
- **A missing file is an error, never a fallback to an example.** `rapidselector.sh` checks that both exist before any Compose command, and stops with a plain message saying which example to copy (otherwise Docker would create a *directory* named `gateway.yaml` for the missing bind mount, and the gateway would fail in a confusing way). The scripts that read `home.env` stop the same way.
- The tests point the scripts and Compose at the example files explicitly (a variable for the folder or for each file, the builder's call), so a run on the owner's machine and in a fresh clone test the same thing.

### `scripts/copy-config.sh`

```
scripts/copy-config.sh to   [<user@host>]   this machine → the host
scripts/copy-config.sh from [<user@host>]   the host → this machine
```

- Asks for `user@host` if it is not given. The SSH password is asked by `ssh` itself; the script never sees it. One password prompt per run.
- Copies exactly `config/gateway.yaml` and `config/home.env`, nothing else. Never `.env`.
- The folder on the host: `RAPIDSELECTOR_REMOTE_DIR` from `config/home.env` if set, otherwise the same path relative to the home directory as this clone (here `~/code/rapid-selector`, which is also where `sandbox`'s clone is). So the owner never types a folder, and `from` works on a fresh machine with no `config/home.env` yet.
- **`to`:** runs the rules check on the local `config/gateway.yaml` and `config/home.env` first and refuses on a broken rule; creates `config/` on the host if needed; then prints the next steps on the host: `./rapidselector.sh restart gateway`, and `setup-keys.sh` if a name or a budget changed.
- **`from`:** before overwriting local files that differ, says which and asks (y/N).
- The usual header, exit codes `0` done, `1` refused (a rule broken, the answer was no), `2` could not run (no SSH, files missing on the host, wrong usage), and a line in `scripts/README.md`.

### Docs that change

- `scripts/README.md`: the rule (`scripts/` runs, `config/` is yours), `copy-config.sh`, and where each script's settings now come from.
- `config/README.md`: each file, which script reads it, how to start from the examples, how to copy.
- `README.md`, first setup: copy the two examples into place and edit them; the address table unchanged.
- `docs/user-guide.md`: every task that edited `gateway/config.yaml` or a script's values (add a model or name, point a role, add or remove a role, change a budget) now edits `config/`, then `copy-config.sh to`, then the steps on the host. No commit is needed for a home's own change.
- `docs/requirements.md` and `docs/roadmap.md`: the parked "repository as code for several homes" becomes this work. Other docs that name `gateway/config.yaml` get the new path, except dated records.
- `CLAUDE.md`'s repository structure gains `config/`, and `gateway/` becomes "request guard": **done in this project** (owner, 2026-11-11), so the next session does not read a wrong map. Nothing else in `CLAUDE.md` changes here; the rest waits for the `CLAUDE.md` cleanup.
- `docker-compose.yml`: `TASK_MODEL_EXTERNAL: chat-tasks`; `tests/chat.bats` checks the role instead of the model name.

### Moving `sandbox` over (the owner's procedure)

Order matters: `git pull` removes the tracked `gateway/config.yaml`, which the running gateway has mounted.
1. Here, on the new branch: `config/gateway.yaml` and `config/home.env` written with exactly today's content and values, plus the role `chat-tasks` in `gateway.yaml`; the rules check and the online price check pass on it.
2. Here: `scripts/copy-config.sh to pi@sandbox`, so `sandbox`'s `config/` holds both files before the pull.
3. On `sandbox`, after the merge: `git pull`, then `./rapidselector.sh restart gateway` (the rules check passes; the gateway now mounts `config/gateway.yaml`), then `./rapidselector.sh up` so `chat` is recreated with `TASK_MODEL_EXTERNAL: chat-tasks`.
4. `setup-keys.sh`: the same teams, keys and budgets as before, plus the role `chat-tasks` (`permanent` 5 names, `experiments` 12).
5. `status.sh`, and the smoke test (under $0.01; its cost confirmed with the owner first), including `--name chat-tasks`; then one new chat in Open WebUI, to see it gets a title (a fraction of a cent).

## Testing

- **The `home.env` check:** each rule refused by a test that fails first (a missing name, a budget that is not a positive number, team budgets above the global budget), and the example and the owner's file passing.
- **Test first, bats, as for the other scripts.** `copy-config.sh` against a stand-in `ssh` on `PATH` that records what it was asked and serves a fake host folder (no network): both directions, the rules check refusing a broken config before anything is sent, the remote folder default and override, the y/N on `from`, and that `.env` is never touched. `rapidselector.sh` refusing without `config/gateway.yaml` or `config/home.env`. `setup-keys.sh` and `check-prices.sh` reading their values from `home.env`, and refusing without it.
- **Every existing suite runs against the example files.** Tests that edit or count the owner's entries (`checks.bats`, `fakes.bats`, `budget-global.bats`, `gateway.bats`, `keys.bats`, the fake upstream) are changed to use the example, and to count its names rather than a fixed 11.
- **What the level 1 suite no longer covers:** the owner's own 11 entries. They are covered by the rules check at every copy and restart, by `check-prices.sh` with the online price comparison, and by the smoke test on the host.
- **A cloud Docker run** of the whole suite before the merge, and the **owner's procedure** on `sandbox` after it.

## Next projects, in order (owner, 2026-11-11)

1. This one.
2. **The docs cleanup:** `decisions.md`, `provider-facts.md` and the procedures, so what is left is relevant to every home.
3. **The `CLAUDE.md` cleanup**, the owner's decision item by item.
4. **The user guide: upgrading one or more containers**, not only the whole stack at once.

The repository structure in `CLAUDE.md` is updated in project 1 already (above).

## Left to the builder

How the tests point at the examples; which 3 entries the example holds, as long as the rules and the price check pass on it; how `copy-config.sh` keeps to one password prompt; the wording of messages; the order of tasks, as long as tests come first and the owner's files exist before `sandbox` pulls.
