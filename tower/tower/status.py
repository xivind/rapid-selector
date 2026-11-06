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
    if now - entry.at > PRICE_CHECK_STALE:
        return Light("caution", f"stale, last {_stamp(entry.at)}")
    if not entry.ok:
        return Light("stop", f"failed, {_stamp(entry.at)}")
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
