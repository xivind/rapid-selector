#!/usr/bin/env bash
# Per completed UTC day and per OpenRouter model id: the spend LiteLLM recorded against what
# OpenRouter charged the inference key, so a model recording the wrong spend (CLAUDE.md
# principle 1) shows up. A line is flagged (!) when it is off by more than $0.05 or 5% of
# OpenRouter's figure, whichever is larger. Run it monthly, and after a model change once a
# day has passed. Names sharing a model id are one line: LiteLLM's daily table merges them
# (docs/provider-facts.md), so per name or per host is not possible here.
# Run:     ./rapidselector.sh run-script scripts/reconcile.sh [--days N] [--prometheus]
#          --days: the N completed UTC days before today (default 7, at most 30, OpenRouter's
#          limit). --prometheus prints Prometheus text format instead (README).
#          RECONCILE_TODAY=YYYY-MM-DD sets "today", for tests only.
# Secrets: OPENROUTER_MANAGEMENT_KEY (read-only use: keys and activity), KEY_SCRIPTS.
#          OPENROUTER_INFERENCE_KEY_NAME from .env.
# Cost:    nothing (no model call).
# Exit:    0 nothing flagged, 1 a line flagged, 2 a source could not be read or wrong usage,
#          3 a missing value.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$ROOT/scripts/lib.sh"

USAGE="usage: reconcile.sh [--days N] [--prometheus]  (N from 1 to 30)"
MAX_PAGES=100

days=7
format=text
while [ "$#" -gt 0 ]; do
  case "$1" in
    --days) [ "$#" -ge 2 ] || die 2 "$USAGE"; days="$2"; shift 2 ;;
    --prometheus) format=prometheus; shift ;;
    *) die 2 "$USAGE" ;;
  esac
done
[[ "$days" =~ ^[1-9][0-9]*$ ]] && [ "$days" -le 30 ] || die 2 "$USAGE"
require_env KEY_SCRIPTS OPENROUTER_MANAGEMENT_KEY RAPIDSELECTOR_LAN_ADDRESS GATEWAY_PORT

today="${RECONCILE_TODAY:-$(date -u +%F)}"
first="$(date -u -d "$today - $days days" +%F)" || die 2 "RECONCILE_TODAY must be a date (YYYY-MM-DD)"
last="$(date -u -d "$today - 1 day" +%F)"

keys="$(or_read '/keys?include_disabled=true')" || die 2 "cannot read OpenRouter's key list"
key_name="${OPENROUTER_INFERENCE_KEY_NAME:-rapidselector-gateway}"
hash="$(inference_key_hash "$keys")" || die 2 "no key named $key_name in OpenRouter's key list"
activity="$(or_read "/activity?api_key_hash=$hash")" || die 2 "cannot read OpenRouter's activity"

pages="[]"
page=1
while :; do
  body="$(gw_read "/user/daily/activity?start_date=$first&end_date=$last&page=$page")" \
    || die 2 "cannot read the gateway's daily activity (page $page)"
  pages="$(jq -c --argjson p "$body" '. + [$p]' <<<"$pages")" || die 2 "unexpected answer from the gateway (page $page)"
  [ "$(jq -r '.metadata.has_more // false' <<<"$body")" = "true" ] || break
  page=$((page + 1))
  [ "$page" -le "$MAX_PAGES" ] || die 2 "the gateway's daily activity has more than $MAX_PAGES pages"
done

report="$(jq -n --argjson gateway "$pages" --argjson activity "$(jq -c '.data' <<<"$activity")" \
  --arg first "$first" --arg last "$last" -f "$ROOT/scripts/jq/reconcile.jq")" \
  || die 2 "unexpected answer from OpenRouter or the gateway (see above)"

if [ "$format" = prometheus ]; then
  jq -r --argjson days "$days" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    [ ["reconcile_flagged_lines", "Day and model lines off by more than max($0.05, 5%).", .flagged],
      ["reconcile_max_abs_diff_usd", "Largest difference between LiteLLM and OpenRouter on one line, USD.", .max_abs_diff_usd],
      ["reconcile_window_days", "Completed UTC days compared.", $days],
      ["reconcile_last_run_timestamp_seconds", "When reconcile.sh last ran, Unix time.", ($now | fromdateiso8601)] ]
    | .[] | "# HELP rapidselector_\(.[0]) \(.[1])\n# TYPE rapidselector_\(.[0]) gauge\nrapidselector_\(.[0]) \(.[2])"
  ' <<<"$report" || die 2 "could not print the report"
else
  jq -r -L "$ROOT/scripts/jq" --arg first "$first" --arg last "$last" 'include "common";
    def pad(n): tostring | . + (" " * n) | .[0:n];
    def row(mark; day; model; g; o; d): "\(mark) \(day | pad(11)) \(model | pad(44)) \(g | pad(11)) \(o | pad(11)) \(d)";
    "LiteLLM against OpenRouter, \($first) to \($last) (completed UTC days)", "",
    if (.lines | length) == 0 then "No spend on either side in this window."
    else
      row(" "; "DAY"; "MODEL"; "GATEWAY"; "OPENROUTER"; "DIFFERENCE"),
      (.days[] as $d
        | (.lines[] | select(.day == $d.day)
            | row(if .flagged then "!" else " " end; .day; .model; .gateway_usd | money; .openrouter_usd | money; .diff_usd | money)),
          row(if $d.flagged then "!" else " " end; $d.day; "total"; $d.gateway_usd | money; $d.openrouter_usd | money; $d.diff_usd | money))
    end,
    "",
    if .flagged == 0 then "Nothing flagged."
    else "\(.flagged) line(s) flagged (!): off by more than $0.05 or 5% of OpenRouter'"'"'s figure." end
  ' <<<"$report" || die 2 "could not print the report"
fi

[ "$(jq '.flagged' <<<"$report")" -eq 0 ] || exit 1
