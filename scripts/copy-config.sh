#!/usr/bin/env bash
# Copy this home's own settings, config/gateway.yaml and config/home.env, to the host or from
# it, over SSH: edit here, copy, then apply on the host. Copies exactly those two files, never
# .env (the host's settings and secrets). With "to", the rules check runs first and a broken
# rule stops the copy; nothing is restarted on the host.
# The folder on the host: RAPIDSELECTOR_REMOTE_DIR in config/home.env if set (absolute, or
# relative to the home directory there), otherwise the same place under the home directory as
# this clone.
# Run:     scripts/copy-config.sh to   [<user@host>]   this machine -> the host
#          scripts/copy-config.sh from [<user@host>]   the host -> this machine
#          It asks for user@host when not given; ssh asks for the password, once per run.
# Secrets: none (the SSH password goes to ssh, never to this script).
# Cost:    nothing.
# Exit:    0 done, 1 refused (a rule is broken, or the answer was no), 2 could not run (no SSH,
#          files missing on the host or here, wrong usage).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/scripts/lib.sh"
set_config_paths "$ROOT"

USAGE="usage: copy-config.sh to|from [<user@host>]"
case "${1:-}" in to | from) ;; *) die 2 "$USAGE" ;; esac
[ "$#" -le 2 ] || die 2 "$USAGE"
direction="$1"
host="${2:-}"
if [ -z "$host" ]; then
  printf 'Host (user@host): ' >&2
  read -r host || true
fi
[ -n "$host" ] || die 2 "no host given; $USAGE"

remote="${RAPIDSELECTOR_REMOTE_DIR:-}"
if [ -z "$remote" ] && [ -f "$HOME_ENV" ]; then
  remote="$(home_env_value "$HOME_ENV" RAPIDSELECTOR_REMOTE_DIR)"
fi
remote="${remote#\~/}"
if [ -z "$remote" ]; then
  case "$ROOT/" in
    "$HOME"/*) remote="${ROOT#"$HOME"/}" ;;
    *) die 2 "this clone is not under $HOME: set RAPIDSELECTOR_REMOTE_DIR in config/home.env" ;;
  esac
fi

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

if [ "$direction" = "to" ]; then
  for file in "$GATEWAY_CONFIG" "$HOME_ENV"; do
    [ -f "$file" ] || die 2 "$file not found: nothing copied"
  done
  rules=0
  RAPIDSELECTOR_HOME_ENV="$HOME_ENV" "$ROOT/scripts/check-prices.sh" --rules-only "$GATEWAY_CONFIG" || rules=$?
  [ "$rules" -ne 1 ] || die 1 "nothing copied: a rule is broken"
  [ "$rules" -eq 0 ] || die 2 "nothing copied: the rules check could not read the config"
  cp "$GATEWAY_CONFIG" "$staging/gateway.yaml"
  cp "$HOME_ENV" "$staging/home.env"
  # cd first: a host without the clone there gets nothing, not a stray config folder.
  tar -C "$staging" -cf - gateway.yaml home.env \
    | ssh "$host" "cd $(printf '%q' "$remote") && mkdir -p config && tar -C config -xf -" \
    || die 2 "could not copy to $host:$remote/config (no clone there, or SSH failed)"
  echo "copied gateway.yaml and home.env to $host:$remote/config"
  echo "next, on the host, in $remote:"
  echo "  ./rapidselector.sh restart gateway"
  echo "  ./rapidselector.sh run-script scripts/setup-keys.sh   (if a name or a budget changed)"
  exit 0
fi

# from: ssh -n, so ssh leaves stdin alone for the question below.
ssh -n "$host" "cd $(printf '%q' "$remote/config") && tar -cf - gateway.yaml home.env" \
  | tar -C "$staging" -xf - \
  || die 2 "could not copy from $host:$remote/config (files missing there, or SSH failed)"
changed=()
[ ! -f "$GATEWAY_CONFIG" ] || cmp -s "$staging/gateway.yaml" "$GATEWAY_CONFIG" || changed+=("$GATEWAY_CONFIG")
[ ! -f "$HOME_ENV" ] || cmp -s "$staging/home.env" "$HOME_ENV" || changed+=("$HOME_ENV")
if [ "${#changed[@]}" -gt 0 ]; then
  printf 'Overwrite %s? (y/N) ' "${changed[*]}" >&2
  answer=""
  read -r answer || true
  case "$answer" in y | Y) ;; *) die 1 "nothing changed" ;; esac
fi
mkdir -p "$(dirname "$GATEWAY_CONFIG")" "$(dirname "$HOME_ENV")"
cp "$staging/gateway.yaml" "$GATEWAY_CONFIG"
cp "$staging/home.env" "$HOME_ENV"
echo "wrote $GATEWAY_CONFIG and $HOME_ENV from $host:$remote/config"
