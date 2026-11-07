"""The status panel's lights and Setup's tab lights. Pure: everything is passed in."""
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Literal

from tower.clients import Unavailable
from tower.summary import Reconciliation

PRICE_CHECK_STALE = timedelta(hours=26)  # the daily run plus a margin, as the alert


@dataclass
class Light:
    colour: Literal["go", "caution", "stop", "off"]
    word: str


def _stamp(at: datetime) -> str:
    return at.astimezone(UTC).strftime("%-d %b %H:%M")


def _gateway_keys(state) -> Light:
    if not state.gateway_read:
        return Light("caution", "cannot read the gateway")
    if state.blocked_by_tower:
        return Light("stop", f"{len(state.blocked_by_tower)} blocked by tower")
    if state.blocked_outside:
        return Light("stop", f"{len(state.blocked_outside)} blocked outside tower")
    return Light("go", "open")


def _openrouter_key(state) -> Light:
    if state.openrouter_disabled is None:
        return Light("caution", "unknown")
    return Light("stop", "disabled") if state.openrouter_disabled else Light("go", "enabled")


def _price_check(entry, now: datetime) -> Light:
    if entry is None:
        return Light("off", "not run yet")
    stale = now - entry.at > PRICE_CHECK_STALE
    if not entry.ok:  # a failure stays red, however old
        return Light("stop", f"failed, {'last ' if stale else ''}{_stamp(entry.at)}")
    if stale:
        return Light("caution", f"stale, last {_stamp(entry.at)}")
    return Light("go", f"ok, {entry.at.astimezone(UTC):%H:%M}")


def _reconciliation(r) -> Light:
    if r is None or isinstance(r, Unavailable):
        return Light("off", "no figures")
    apart = f"${abs(r.diff_usd):.2f} apart"
    if r.flagged:
        return Light("stop", apart)
    return Light("go", "in step" if abs(r.diff_usd) < 0.01 else apart)


def panel_lights(state, price_check, reconciliation: Reconciliation | Unavailable | None,
                 now: datetime) -> dict[str, Light]:
    return {
        "gateway_keys": _gateway_keys(state),
        "openrouter_key": _openrouter_key(state),
        "price_check": _price_check(price_check, now),
        "reconciliation": _reconciliation(reconciliation),
    }


def reconciliation_now(gw, orc, now: datetime, end: float) -> Reconciliation | Unavailable:
    """This month's gateway spend against the key's usage_monthly, read within `end`. The
    clients' 30-second cache makes this cheap right after a page has read the same."""
    from tower import setup_view  # imported here: setup_view imports the kill switch
    from tower.summary import period_bounds, reconcile

    start, stop = period_bounds(now)["month"]
    got = setup_view.gather({"usage": ("gateway", lambda: gw.usage(start.date(), now.date())),
                             "key": ("openrouter", lambda: orc.inference_key())}, end)
    for value in got.values():
        if isinstance(value, Unavailable):
            return value
    try:
        spent = sum(r.spend_usd for r in got["usage"] if start.date() <= r.day < stop.date())
        return reconcile(spent, float(got["key"]["usage_monthly"]))
    except Exception as e:  # a malformed answer shows as no figures
        return Unavailable("gateway", type(e).__name__)


TEAM_CAUTION, TEAM_STOP = 0.20, 0.10  # share of a team's budget left, as the budget alerts
KEY_EXPIRY_CAUTION_DAYS = 30


def _models_tab(models) -> Light:
    results = [m.get("price_check") for m in models or []]
    if not any(results):
        return Light("off", "not checked")
    if any(r and r != "ok" for r in results):
        return Light("stop", "a price check failed")
    if not all(results):
        return Light("caution", "a model not checked yet")
    return Light("go", "prices ok")


def _teams_tab(teams) -> Light:
    if teams is None:
        return Light("off", "cannot be read")
    worst = Light("go", "budgets ok")
    for t in teams:
        if t.get("blocked") or any(k.get("blocked") for k in t.get("keys") or []):
            return Light("stop", "a key is blocked")
        budget, spend = t.get("budget"), t.get("spend")
        if t.get("id") and budget and spend is not None:
            left = (budget - spend) / budget
            if left < TEAM_STOP:
                return Light("stop", f"{t.get('alias')} under 10% left")
            if left < TEAM_CAUTION:
                worst = Light("caution", f"{t.get('alias')} under 20% left")
    return worst


def _openrouter_tab(key, management) -> Light:
    if key is None:
        return Light("off", "cannot be read")
    days = (management or {}).get("days_left")
    if key.get("disabled"):
        return Light("stop", "inference key disabled")
    if days is not None and days < 0:
        return Light("stop", "management key expired")
    if days is None:
        return Light("caution", "management key expiry unknown")
    if days < KEY_EXPIRY_CAUTION_DAYS:
        return Light("caution", f"management key: {days} days left")
    return Light("go", "keys ok")


def _gateway_tab(view) -> Light:
    if "gateway" in (view.get("missing") or []):
        return Light("off", "cannot be read")
    settings = view.get("gateway_settings") or []
    budget = next((g["value"] for g in settings if g["name"] == "global budget"), None)
    teams = view.get("teams_and_keys")
    if budget is not None and teams is not None:
        total = sum(t["budget"] for t in teams if t.get("id") and t.get("budget") is not None)
        if total > float(budget) + 1e-6:  # principle 1: the team budgets must fit in the global one
            return Light("stop", f"team budgets ${total:,.2f} add up to more than the global budget ${float(budget):,.2f}")
    if any(g["value"] is None for g in settings):
        return Light("caution", "a setting cannot be read")
    return Light("go", "settings read")


def tab_lights(view: dict, now: datetime) -> dict[str, Light]:
    """Setup's tabs: one light each."""
    secrets = view.get("secrets") or []
    return {
        "models": _models_tab(view.get("models")),
        "teams_and_keys": _teams_tab(view.get("teams_and_keys")),
        "openrouter": _openrouter_tab(view.get("openrouter_key"), view.get("management_key")),
        "gateway": _gateway_tab(view),
        "open_webui": Light("go", "read from docker-compose.yml") if view.get("open_webui") is not None
        else Light("off", "docker-compose.yml cannot be read"),
        "secrets": Light("stop", "a secret is not set") if any(s != "set" for _, s in secrets)
        else Light("go", "all set"),
    }
