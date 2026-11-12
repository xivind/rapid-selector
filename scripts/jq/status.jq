# The report behind scripts/status.sh, from the raw answers it fetched. Called as
#   jq -n --arg now <ISO UTC> --arg expires <ISO date or ""> --arg key_name <name>
#     --argjson credits <GET /api/v1/credits> --argjson key <GET /api/v1/keys/{hash}>
#     --argjson global <GET /global/spend> --argjson teams '[<GET /team/info>, ...]' -f status.jq
# Returns {balance_usd, key, forecast_month_usd, gateway, teams, management_key_days_left,
# warnings}; status.sh renders it and exits 1 when warnings is not empty.
include "common" {search: "./"};

# The thresholds (CLAUDE.md principle 1; docs/provider-facts.md, "Low balance and latency").
def low_balance_usd: 10;
def budget_warn_share: 0.8;
def key_expiry_warn_days: 30;

($now | epoch) as $t
| ($t | gmtime) as $g
| ([$g[0], $g[1], 1, 0, 0, 0, 0, 0] | mktime) as $month_start
| ([$g[0], $g[1] + 1, 1, 0, 0, 0, 0, 0] | mktime) as $next_month
| (($next_month - $month_start) / 86400) as $days_in_month
| ([($t - $month_start) / 86400, 1] | max) as $days_elapsed
| $key.data as $k
| ($credits.data.total_credits - $credits.data.total_usage) as $balance
| (if $expires == "" then null else (($expires | epoch) - $t) / 86400 | floor end) as $days_left
| [$teams[] | .team_info | {id: .team_id, spend_usd: .spend, budget_usd: .max_budget, reset_at: .budget_reset_at}] as $team_rows
| ([{name: "the global budget", spend_usd: $global.spend, budget_usd: $global.max_budget}]
   + [$team_rows[] | {name: "team \(.id)'s budget", spend_usd, budget_usd}]) as $budgets
| {
    balance_usd: $balance,
    key: {name: $key_name, disabled: $k.disabled, limit_usd: $k.limit, remaining_usd: $k.limit_remaining,
          usage_day_usd: $k.usage_daily, usage_week_usd: $k.usage_weekly, usage_month_usd: $k.usage_monthly,
          limit_reset: $k.limit_reset},
    forecast_month_usd: ($k.usage_monthly / $days_elapsed * $days_in_month),
    gateway: {spend_usd: $global.spend, budget_usd: $global.max_budget},
    teams: $team_rows,
    management_key_days_left: $days_left,
    warnings: (
      [ if $balance < low_balance_usd then
          "balance \($balance | money) is below \(low_balance_usd | money): OpenRouter adds billing checks, so calls get slower and speed comparisons are unreliable"
        else empty end ]
      + [ if $k.disabled then "the inference key \($key_name) is disabled: every model call fails" else empty end ]
      + [ $budgets[] | select(.budget_usd != null and .budget_usd > 0 and .spend_usd > budget_warn_share * .budget_usd)
          | "\(.name) is \(.spend_usd / .budget_usd * 100 | floor)% spent (\(.spend_usd | money) of \(.budget_usd | money))" ]
      + [ if $k.limit_reset != "monthly" then
            "the inference key's limit resets \($k.limit_reset // "never"), not monthly like the gateway's budgets"
          else
            $team_rows[] | select(.budget_usd != null and ((.reset_at // "" | if . == "" then null else epoch end) != $next_month))
            | "team \(.id)'s budget resets on \(.reset_at // "no date"), OpenRouter's key limit on \($next_month | todate | .[0:10])"
          end ]
      + [ if $days_left == null then empty
          elif $days_left < 0 then "the management key expired on \($expires[0:10]): make a new one in OpenRouter's dashboard"
          elif $days_left < key_expiry_warn_days then
            "the management key expires in \($days_left) days (\($expires[0:10])): make a new one in OpenRouter's dashboard"
          else empty end ]
    )
  }
