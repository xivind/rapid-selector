#!/usr/bin/env bash
# ONE-OFF, for docs/test-procedures/ops-scripts.md (step A6); deleted from the repository once
# the owner has run it. Removes what tower left in the gateway: every key with alias "tower",
# then the user "tower". Safe to run twice.
# Run:     ./rapidselector.sh run-script scripts/cleanup-tower-user.sh
# Secrets: LITELLM_MASTER_KEY.
# Cost:    nothing.
# Exit:    0 removed, or nothing to remove; 1 the gateway refused or could not be read;
#          3 a missing value.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/scripts/lib.sh"

require_env LITELLM_MASTER_KEY RAPIDSELECTOR_LAN_ADDRESS GATEWAY_PORT

removed=0
keys="$(api GET '/key/list?return_full_object=true&size=100')" || die 1 "cannot read /key/list from the gateway"
# Key hashes, not values: the list holds no key value, and /key/delete takes hashes too.
hashes="$(jq -c '[.keys[] | select(.key_alias == "tower") | .token]' <<<"$keys")"
count="$(jq length <<<"$hashes")"
if [ "$count" -gt 0 ]; then
  api POST /key/delete "$(jq -c '{keys: .}' <<<"$hashes")" >/dev/null || die 1 "could not delete the key(s) with alias tower"
  echo "removed: $count key(s) with alias tower"
  removed=1
fi

if user="$(api GET '/user/info?user_id=tower' 2>/dev/null)" && [ "$(jq '.user_info != null' <<<"$user")" = "true" ]; then
  api POST /user/delete '{"user_ids":["tower"]}' >/dev/null || die 1 "could not delete the user tower"
  echo "removed: user tower"
  removed=1
fi

[ "$removed" -eq 1 ] || echo "nothing to remove: no key with alias tower and no user tower"
