#!/usr/bin/env bash
# Check that every pinned image exists for linux/arm64 (the Raspberry Pi 5), without pulling.
# Usage: tests/check-arm64.sh [compose files...]  (default: docker-compose.yml, the test fakes and tower's Dockerfile)
# Images we build ourselves (rapidselector-*) are skipped; the images our Dockerfile builds on are checked.
set -uo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
dockerfiles=()
if [ "$#" -eq 0 ]; then
  set -- "$repo/docker-compose.yml" "$repo/tests/compose.fakes.yml"
  dockerfiles=("$repo/tower/Dockerfile")
fi

mapfile -t images < <({
  grep -hE '^[[:space:]]+image:' "$@" | awk '{ print $2 }' | tr -d '"'
  [ "${#dockerfiles[@]}" -eq 0 ] || {
    grep -hE '^FROM ' "${dockerfiles[@]}" | awk '{ print $2 }'
    grep -hE '^COPY --from=' "${dockerfiles[@]}" | sed -E 's/^COPY --from=([^ ]+).*/\1/'
  }
} | grep -v '^rapidselector-' | sort -u)
failed=0
for image in "${images[@]}"; do
  out=""
  for attempt in 1 2 3; do
    # Docker Hub may answer 429 (rate limit); wait and try again.
    if out="$(docker buildx imagetools inspect "$image" 2>&1)"; then break; fi
    [[ "$out" == *"429"* ]] || break
    sleep $((attempt * 10))
  done
  if grep -qE 'Platform:[[:space:]]+linux/arm64' <<<"$out"; then
    echo "ok $image"
  else
    echo "MISSING linux/arm64: $image ($(head -c 200 <<<"$out" | tr '\n' ' '))"
    failed=1
  fi
done
exit "$failed"
