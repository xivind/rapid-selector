"""Cost summary, usage tables and reconciliation. Pure logic: no I/O, `now` is passed in, all UTC."""

import calendar
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import UTC, date, datetime, timedelta
from typing import Literal

from tower.clients import UsageRow, Unavailable

RECONCILE_FLOOR_USD = 0.05
RECONCILE_FRACTION = 0.05


def _utc(now: datetime) -> datetime:
    return now.astimezone(UTC)


def _next_month(d: datetime) -> datetime:
    return d.replace(year=d.year + (d.month == 12), month=d.month % 12 + 1, day=1)


def period_bounds(now: datetime) -> dict[str, tuple[datetime, datetime]]:
    """[start, end) for the UTC day, the week from Monday, and the month."""
    now = _utc(now)
    day = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week = day - timedelta(days=day.weekday())
    month = day.replace(day=1)
    return {
        "day": (day, day + timedelta(days=1)),
        "week": (week, week + timedelta(days=7)),
        "month": (month, _next_month(month)),
    }


def previous_stretches(now: datetime) -> dict[str, tuple[datetime, datetime]]:
    """[start, end) of the same stretch one period back: yesterday; last week from Monday to the
    same weekday; last month from the 1st to the same day, cut at that month's last day."""
    now = _utc(now)
    day = now.replace(hour=0, minute=0, second=0, microsecond=0)
    week = day - timedelta(days=day.weekday()) - timedelta(days=7)
    first = day.replace(day=1)
    last_month = (first - timedelta(days=1)).replace(day=1)
    days_in_last = calendar.monthrange(last_month.year, last_month.month)[1]
    return {
        "day": (day - timedelta(days=1), day),
        "week": (week, week + timedelta(days=day.weekday() + 1)),
        "month": (last_month, last_month + timedelta(days=min(day.day, days_in_last))),
    }


@dataclass
class Change:
    kind: Literal["up", "down", "same", "new"]
    pct: float | None


def change(current: float, previous: float) -> Change | None:
    """None when both are 0; "new" when only the previous is; "same" under half a percent."""
    if not previous:
        return Change("new", None) if current else None
    pct = (current - previous) / previous * 100
    if abs(pct) < 0.5:
        return Change("same", abs(pct))
    return Change("up" if pct > 0 else "down", abs(pct))


def forecast(spent_month: float, now: datetime) -> float:
    now = _utc(now)
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    elapsed = (now - start).total_seconds() / 86400
    return spent_month / max(elapsed, 1.0) * calendar.monthrange(now.year, now.month)[1]


@dataclass
class Reconciliation:
    gateway_usd: float
    openrouter_usd: float
    diff_usd: float  # gateway minus OpenRouter
    diff_pct: float | None  # of OpenRouter's figure; None when that is 0
    flagged: bool


def _flagged(gateway: float, openrouter: float) -> bool:
    return abs(gateway - openrouter) > max(RECONCILE_FLOOR_USD, RECONCILE_FRACTION * openrouter)


def reconcile(gateway_usd: float, openrouter_usd: float) -> Reconciliation:
    diff = gateway_usd - openrouter_usd
    pct = diff / openrouter_usd * 100 if openrouter_usd else None
    return Reconciliation(gateway_usd, openrouter_usd, diff, pct, _flagged(gateway_usd, openrouter_usd))


def _slug_host(entry: dict) -> str:
    order = entry["litellm_params"]["extra_body"]["provider"]["order"][0]
    return order.split("/")[0].lower()


def _info(models: list[dict]) -> dict[str, tuple[str, str, str]]:
    """name -> (kind, model id, host)."""
    out = {}
    for e in models:
        try:
            model = e["litellm_params"]["model"].removeprefix("openrouter/")
            out[e["model_name"]] = (
                e.get("model_info", {}).get("rapidselector_kind", "experiment"),
                model,
                _slug_host(e),
            )
        except (KeyError, IndexError, TypeError):
            continue
    return out


@dataclass
class DayLine:
    day: date
    model: str
    host: str
    gateway_usd: float
    openrouter_usd: float
    flagged: bool


def reconcile_days(rows, activity, models, today_openrouter_usd, today) -> list[DayLine]:
    """Per day and model@host. Today has one line (model "all models", host "") from the key's usage_daily.

    Activity rows carry the day in `date` (the docs were not checked for the field name).
    """
    info = _info(models)
    gw: dict[tuple, float] = defaultdict(float)
    for r in rows:
        if r.name in info and r.day < today:
            gw[(r.day, info[r.name][1], info[r.name][2])] += r.spend_usd
    orr: dict[tuple, float] = defaultdict(float)
    for a in activity:
        day = date.fromisoformat(str(a["date"])[:10])
        if day < today:
            orr[(day, a["model"], str(a.get("provider_name", "")).lower())] += float(a.get("usage") or 0.0)
    lines = [
        DayLine(k[0], k[1], k[2], gw.get(k, 0.0), orr.get(k, 0.0), _flagged(gw.get(k, 0.0), orr.get(k, 0.0)))
        for k in sorted(set(gw) | set(orr))
    ]
    today_gw = sum(r.spend_usd for r in rows if r.day == today)
    lines.append(DayLine(today, "all models", "", today_gw, today_openrouter_usd,
                         _flagged(today_gw, today_openrouter_usd)))
    return lines


@dataclass
class Ranked:
    label: str
    calls: int
    spend_usd: float


def _in(r: UsageRow, start: datetime, end: datetime) -> bool:
    return start.date() <= r.day < end.date()


def _rank(rows, start, end, label_of) -> list[Ranked]:
    acc: dict[str, list] = defaultdict(lambda: [0, 0.0])
    for r in rows:
        label = label_of(r.name)
        if label and _in(r, start, end):
            acc[label][0] += r.calls
            acc[label][1] += r.spend_usd
    out = [Ranked(k, v[0], v[1]) for k, v in acc.items()]
    return sorted(out, key=lambda x: (-x.spend_usd, -x.calls, x.label))


def top_roles(rows, models, start, end) -> list[Ranked]:
    info = _info(models)
    return _rank(rows, start, end, lambda n: n if info.get(n, ("",))[0] == "role" else None)


def top_models(rows, models, start, end) -> list[Ranked]:
    info = _info(models)
    return _rank(rows, start, end, lambda n: f"{info[n][1]}@{info[n][2]}" if n in info else None)


@dataclass
class Totals:
    calls: int = 0
    tokens_in: int = 0
    tokens_out: int = 0
    spend_usd: float = 0.0


@dataclass
class UsageLine:
    label: str
    day: Totals
    week: Totals
    month: Totals
    yesterday: Totals = field(default_factory=Totals)
    week_before: Totals = field(default_factory=Totals)
    month_before: Totals = field(default_factory=Totals)


@dataclass
class UsageTable:
    roles: list[UsageLine]
    experiments: list[UsageLine]
    keys: list[UsageLine]


_STRETCHES = (("day", "day"), ("week", "week"), ("month", "month"),
              ("yesterday", "before_day"), ("week_before", "before_week"), ("month_before", "before_month"))


def _lines(rows, bounds, label_of) -> list[UsageLine]:
    """bounds: period_bounds plus previous_stretches as before_day, before_week, before_month."""
    acc: dict[str, UsageLine] = {}
    for r in rows:
        label = label_of(r)
        line = acc.setdefault(label, UsageLine(label, Totals(), Totals(), Totals()))
        for attr, period in _STRETCHES:
            if period in bounds and _in(r, *bounds[period]):
                t = getattr(line, attr)
                t.calls += r.calls
                t.tokens_in += r.tokens_in
                t.tokens_out += r.tokens_out
                t.spend_usd += r.spend_usd
    return sorted((x for x in acc.values() if x.month.calls or x.week.calls or x.day.calls
                   or x.month.spend_usd or x.week.spend_usd or x.day.spend_usd),
                  key=lambda x: (-x.month.spend_usd, x.label))


def usage_tables(rows, models, now) -> UsageTable:
    """Names missing from /model/info are listed with the experiments, so their spend stays visible."""
    bounds = {**period_bounds(now), **{f"before_{k}": v for k, v in previous_stretches(now).items()}}
    info = _info(models)
    is_role = lambda r: info.get(r.name, ("experiment",))[0] == "role"  # noqa: E731
    return UsageTable(
        roles=_lines([r for r in rows if is_role(r)], bounds, lambda r: r.name),
        experiments=_lines([r for r in rows if not is_role(r)], bounds, lambda r: r.name),
        keys=_lines(rows, bounds, lambda r: r.key_alias or "(no alias)"),
    )


@dataclass
class CostSummary:
    spend_day_usd: float | None
    spend_week_usd: float | None
    spend_month_usd: float | None
    balance_usd: float | None
    limit_usd: float | None
    limit_remaining_usd: float | None
    global_budget_usd: float | None
    forecast_usd: float | None
    key_reset: str | None  # the OpenRouter key's limit_reset
    gateway_window: str | None  # the gateway's global budget window, from gateway/config.yaml
    resets_agree: bool | None  # None when either side is unknown
    next_reset: datetime  # 1st of next month 00:00 UTC, for both
    top_roles: list[Ranked] | None
    top_models: list[Ranked] | None
    reconciliation: Reconciliation | None
    spend_yesterday_usd: float | None  # the gateway's, as is week_change
    week_change: Change | None
    price_check: object  # latest LogEntry or None
    smoke_test: object
    missing: list[str]  # sources that were Unavailable: "gateway", "openrouter"


def _ok(value, missing: set, source: str):
    if isinstance(value, Unavailable):
        missing.add(source)
        return None
    return value


def cost_summary(*, inference_key, credits, usage, models, global_budget, global_window,
                 price_check, smoke_test, now, period: str = "month") -> CostSummary:
    """Each of inference_key, credits (OpenRouter) and usage, models, global_budget (gateway) is the
    value or an Unavailable. global_window is a string from config.yaml or None. A source that is
    down gives None in its fields and is listed in `missing`."""
    missing: set[str] = set()
    key = _ok(inference_key, missing, "openrouter")
    cred = _ok(credits, missing, "openrouter")
    rows = _ok(usage, missing, "gateway")
    mods = _ok(models, missing, "gateway")
    budget = _ok(global_budget, missing, "gateway")

    month_spend = key.get("usage_monthly") if key else None
    reset = key.get("limit_reset") if key else None
    bounds = period_bounds(now)
    if key is None or global_window is None:
        agree = None
    else:
        agree = reset == "monthly" and global_window == "30d"
    gw_month = sum(r.spend_usd for r in rows if _in(r, *bounds["month"])) if rows is not None else None
    before = previous_stretches(now)
    spent = (lambda start, end: sum(r.spend_usd for r in rows if _in(r, start, end))) if rows is not None else None
    return CostSummary(
        spend_day_usd=key.get("usage_daily") if key else None,
        spend_week_usd=key.get("usage_weekly") if key else None,
        spend_month_usd=month_spend,
        balance_usd=cred["total_credits"] - cred["total_usage"] if cred else None,
        limit_usd=key.get("limit") if key else None,
        limit_remaining_usd=key.get("limit_remaining") if key else None,
        global_budget_usd=budget,
        forecast_usd=forecast(month_spend, now) if month_spend is not None else None,
        key_reset=reset,
        gateway_window=global_window,
        resets_agree=agree,
        next_reset=bounds["month"][1],
        top_roles=top_roles(rows, mods, *bounds[period]) if rows is not None and mods is not None else None,
        top_models=top_models(rows, mods, *bounds[period]) if rows is not None and mods is not None else None,
        reconciliation=reconcile(gw_month, month_spend) if gw_month is not None and month_spend is not None else None,
        spend_yesterday_usd=spent(*before["day"]) if spent else None,
        week_change=change(spent(*bounds["week"]), spent(*before["week"])) if spent else None,
        price_check=price_check,
        smoke_test=smoke_test,
        missing=sorted(missing),
    )


STANDOUT_FACTOR = 2.0
STANDOUT_MIN_LINES = 3
_PERIODS = ("day", "week", "month")
_COLUMNS = ("spend_usd", "calls", "tokens_in", "tokens_out")


def standouts(lines: list[UsageLine]) -> set[tuple[str, str, str]]:
    """(label, period, column) of each figure above 0 that is more than twice the mean of the
    other lines' figures in the same period and column. None in a table of under three lines."""
    if len(lines) < STANDOUT_MIN_LINES:
        return set()
    out = set()
    for period in _PERIODS:
        for column in _COLUMNS:
            values = [getattr(getattr(line, period), column) for line in lines]
            total = sum(values)
            for line, value in zip(lines, values):
                others = (total - value) / (len(values) - 1)
                if value > 0 and value > STANDOUT_FACTOR * others:
                    out.add((line.label, period, column))
    return out
