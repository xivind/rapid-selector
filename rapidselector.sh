#!/usr/bin/env bash
# Load settings and secrets, then run docker compose.
#   ./rapidselector.sh up -d | down | logs -f | ps | <any docker compose command>
#   ./rapidselector.sh update   (pull new images, then recreate what changed)
# Settings come from .env (or $RAPIDSELECTOR_ENV_FILE). Secrets come from .env or,
# with SECRETS_SOURCE=secrets-service, from the secret "rapidselector" in secrets-service.
set -euo pipefail

RAPIDSELECTOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RAPIDSELECTOR_ROOT
# shellcheck source=SCRIPTDIR/scripts/lib.sh
. "$RAPIDSELECTOR_ROOT/scripts/lib.sh"

load_settings_and_secrets

if [ "${1:-}" = "update" ]; then
  shift
  docker compose "$@" pull
  exec docker compose "$@" up -d
fi

exec docker compose "$@"
