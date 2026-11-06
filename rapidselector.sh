#!/usr/bin/env bash
# Load settings and secrets, then run docker compose.
#   ./rapidselector.sh up | down | logs -f | ps | <any docker compose command>
#   (up always runs detached)
#   ./rapidselector.sh update   (pull new images, rebuild tower, then recreate what changed)
#   ./rapidselector.sh run-script scripts/setup-keys.sh   (run one of our scripts with the secrets)
# Settings come from .env (or $RAPIDSELECTOR_ENV_FILE). Secrets come from .env or,
# with SECRETS_SOURCE=secrets-service, from the secret "rapidselector" in secrets-service.
set -euo pipefail

RAPIDSELECTOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RAPIDSELECTOR_ROOT
# shellcheck source=SCRIPTDIR/scripts/lib.sh
. "$RAPIDSELECTOR_ROOT/scripts/lib.sh"

load_settings_and_secrets

if [ "${1:-}" = "run-script" ]; then
  shift
  [ "$#" -ge 1 ] || die 2 "usage: rapidselector.sh run-script <script> [args...]"
  exec "$@"
fi

if [ "${1:-}" = "up" ]; then
  shift
  [ "${1:-}" != "-d" ] || shift
  exec docker compose up -d "$@"
fi

if [ "${1:-}" = "update" ]; then
  shift
  # Tower's image is built here, not pulled: a pull of it fails and would stop the update.
  docker compose "$@" pull --ignore-buildable
  exec docker compose "$@" up -d --build
fi

exec docker compose "$@"
