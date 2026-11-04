#!/usr/bin/env bash
# Level 1 regression suite: run after any change.
# Usage: tests/run.sh [bats files...]   (default: every tests/*.bats)
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo" || exit 1

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. In the cloud sandbox, start it first: dockerd > /tmp/dockerd.log 2>&1 &" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=(tests/*.bats)
fi

failed=()
for file in "${files[@]}"; do
  echo "== $file"
  if ! npx --yes bats@1.11.0 "$file"; then
    failed+=("$file")
  fi
done

# Stop any test stack a failing file left behind.
docker compose --project-directory "$repo" -f tests/compose.fakes.yml down -v >/dev/null 2>&1 || true
if [ -f docker-compose.yml ] && [ -f tests/.artifacts/test.env ]; then
  docker compose --project-directory "$repo" --env-file tests/.artifacts/test.env \
    -f docker-compose.yml -f tests/compose.fakes.yml -f tests/compose.test.yml down -v >/dev/null 2>&1 || true
fi

if [ "${#failed[@]}" -gt 0 ]; then
  echo "FAILED: ${failed[*]}" >&2
  exit 1
fi
echo "All ${#files[@]} test files passed."
