#!/usr/bin/env bash
# Extended mode only. Runs status.sh and reconcile.sh with --prometheus and puts their output in
# node_exporter's textfile directory, for Grafana's alerts and dashboard. Each file is written
# to a temporary name first and then moved, so node_exporter never reads half a file. A script
# that could not run (exit 2 or more) leaves its old file in place, so Grafana sees it go stale
# (rapidselector_status_last_run_timestamp_seconds); a warning (exit 1) still writes the file.
# Run:     scripts/write-metrics.sh [directory]   (default /var/lib/node_exporter/textfile),
#          on the host, hourly from cron (README, "Optional: cost figures in Prometheus").
# Secrets: those of status.sh and reconcile.sh, loaded by rapidselector.sh. Without the optional
#          management key both exit 3, so no file is written and this exits 2 every run: leave
#          the cron line out then (scripts/README.md, "Without the management key").
# Cost:    nothing (no model call).
# Exit:    0 both files written, 2 one or both could not be written (the reason on stderr).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="${1:-/var/lib/node_exporter/textfile}"
[ -d "$dir" ] && [ -w "$dir" ] || { echo "rapidselector: cannot write to $dir" >&2; exit 2; }

failed=0
for name in status reconcile; do
  # The temporary name does not end in .prom, so node_exporter ignores it.
  tmp="$(mktemp "$dir/.rapidselector_$name.XXXXXX")" || { echo "rapidselector: cannot write to $dir" >&2; exit 2; }
  # The full path: rapidselector.sh runs the script from the current directory, which cron sets
  # to the home directory.
  "$ROOT/rapidselector.sh" run-script "$ROOT/scripts/$name.sh" --prometheus > "$tmp"
  code=$?
  if [ "$code" -le 1 ]; then
    chmod 644 "$tmp"
    mv "$tmp" "$dir/rapidselector_$name.prom"
  else
    rm -f "$tmp"
    echo "rapidselector: $name.sh exited $code; $dir/rapidselector_$name.prom not updated" >&2
    failed=1
  fi
done
[ "$failed" -eq 0 ] || exit 2
