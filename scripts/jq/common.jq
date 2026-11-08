# Shared jq definitions for scripts/status.sh and scripts/reconcile.sh (jq 1.6).

# fixed(n): a number as text with n decimals, e.g. 19.3 | fixed(2) = "19.30".
def fixed(n):
  (if . < 0 then "-" else "" end) as $sign
  | ((if . < 0 then -. else . end) * pow(10; n) | round | tostring) as $digits
  | ([range([n + 1 - ($digits | length), 0] | max)] | map("0") | join("") + $digits) as $p
  | $sign + $p[0:($p | length) - n] + "." + $p[($p | length) - n:];

# money: "$19.30"; below one cent "$0.0012", below a hundredth of a cent "$0.000001";
# negative as "-$0.19"; null as "-".
def money:
  if . == null then "-"
  else (if . < 0 then -. else . end) as $a
    | (if . < 0 then "-$" else "$" end)
      + ($a | if . != 0 and . < 0.0001 then fixed(6) elif . != 0 and . < 0.01 then fixed(4) else fixed(2) end)
  end;

# epoch: an ISO date or time from LiteLLM or OpenRouter as seconds; fractions and offsets dropped.
def epoch: if length == 10 then . + "T00:00:00Z" else .[0:19] + "Z" end | fromdateiso8601;
