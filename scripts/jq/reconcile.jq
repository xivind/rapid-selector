# The report behind scripts/reconcile.sh: per UTC day and OpenRouter model id, the spend
# LiteLLM recorded against what OpenRouter charged. Called as
#   jq -n --argjson gateway '[<GET /user/daily/activity page>, ...]'
#     --argjson activity <GET /api/v1/activity .data> --arg first <YYYY-MM-DD> --arg last <YYYY-MM-DD>
#     -f reconcile.jq
# Returns {lines: [{day, model, gateway_usd, openrouter_usd, diff_usd, flagged}],
# days: [{day, gateway_usd, openrouter_usd, diff_usd, flagged}], flagged, max_abs_diff_usd}.
# Gateway side: breakdown.models (per model id, so names sharing a model id are already added
# together by LiteLLM; docs/provider-facts.md), over every page. OpenRouter side: usage over
# every provider_name (endpoint tag) of the model. diff = gateway - OpenRouter.

# A line is flagged when the difference is more than $0.05 or 5% of OpenRouter's figure,
# whichever is larger.
def flag_floor_usd: 0.05;
def flag_share: 0.05;
def flagged($g; $o): (($g - $o) | fabs) > ([flag_floor_usd, flag_share * $o] | max);

# totals: [{day, model, usd}] as {"<day>|<model>": usd}.
def totals: group_by([.day, .model]) | map({key: "\(.[0].day)|\(.[0].model)", value: (map(.usd) | add)}) | from_entries;

def in_window: . >= $first and . <= $last;

([$gateway[] | .results[] | select(.date[0:10] | in_window) | .date[0:10] as $d
  | .breakdown.models | to_entries[] | {day: $d, model: (.key | sub("^openrouter/"; "")), usd: (.value.metrics.spend // 0)}]
 | totals) as $gateway_totals
| ([$activity[] | select(.date[0:10] | in_window) | {day: .date[0:10], model, usd: (.usage // 0)}] | totals) as $openrouter
| ([$gateway_totals, $openrouter | keys[]] | unique
   | map(split("|") as [$day, $model] | ($gateway_totals[.] // 0) as $g | ($openrouter[.] // 0) as $o
       | {day: $day, model: $model, gateway_usd: $g, openrouter_usd: $o, diff_usd: ($g - $o), flagged: flagged($g; $o)})
   | group_by(.day) | reverse | map(sort_by(.model)) | add // []) as $lines
| {
    lines: $lines,
    days: ($lines | group_by(.day) | reverse
      | map({day: .[0].day, gateway_usd: (map(.gateway_usd) | add), openrouter_usd: (map(.openrouter_usd) | add),
             flagged: any(.[]; .flagged)} | .diff_usd = (.gateway_usd - .openrouter_usd))
      | map({day, gateway_usd, openrouter_usd, diff_usd, flagged})),
    flagged: ($lines | map(select(.flagged)) | length),
    max_abs_diff_usd: ($lines | map(.diff_usd | fabs) | max // 0)
  }
