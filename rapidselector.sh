#!/usr/bin/env bash
# Load settings and secrets, then run docker compose.
#   ./rapidselector.sh up | down | logs -f | ps | <any docker compose command>
#   (up always runs detached)
#   ./rapidselector.sh update   (pull new images, then recreate what changed)
#   ./rapidselector.sh run-script scripts/setup-keys.sh   (run one of our scripts with the secrets)
#   ./rapidselector.sh restart gateway   (checks gateway/config.yaml's rules first; refuses with
#                                         exit 5 if one is broken; also for restart with no service)
# Settings come from .env (or $RAPIDSELECTOR_ENV_FILE). Secrets come from .env or,
# with SECRETS_SOURCE=secrets-service, from the secret "rapidselector" in secrets-service.
set -euo pipefail

RAPIDSELECTOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RAPIDSELECTOR_ROOT
# shellcheck source=SCRIPTDIR/scripts/lib.sh
. "$RAPIDSELECTOR_ROOT/scripts/lib.sh"

if [ "${1:-}" = "run-script" ]; then load_settings_and_secrets with-optional; else load_settings_and_secrets; fi

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
  docker compose "$@" pull
  exec docker compose "$@" up -d
fi

# A model change is applied by restarting the gateway, so check the config's rules first
# (scripts/check-prices.sh --rules-only, offline). A reboot or up still starts whatever it holds.
if [ "${1:-}" = "restart" ]; then
  named=()
  skip=0
  for arg in "${@:2}"; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$arg" in
      -t | --timeout) skip=1 ;;
      -*) ;;
      *) named+=("$arg") ;;
    esac
  done
  if [ "${#named[@]}" -eq 0 ] || [[ " ${named[*]} " == *" gateway "* ]]; then
    rules=0
    "$RAPIDSELECTOR_ROOT/scripts/check-prices.sh" --rules-only \
      "${RAPIDSELECTOR_GATEWAY_CONFIG:-$RAPIDSELECTOR_ROOT/gateway/config.yaml}" || rules=$?
    [ "$rules" -ne 1 ] || die 5 "gateway not restarted: gateway/config.yaml breaks a rule"
    [ "$rules" -eq 0 ] || die 5 "gateway not restarted: the rules check could not read the config"
  fi
fi

exec docker compose "$@"
