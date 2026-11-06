"""The background loop: every minute it updates the metrics, keeps level 1 enforced,
takes an hourly balance snapshot and runs the daily price check."""
import logging
import threading
from datetime import UTC, datetime, time as dtime, timedelta

from tower import checks, killswitch, metrics, setup_view, store
from tower.app import USAGE_DAYS, _summary
from tower.clients import Unavailable

log = logging.getLogger("tower.loop")
INTERVAL = 60.0
SNAPSHOT_EVERY = timedelta(hours=1)
CHECK_AT = dtime(6, 30)


def _step(name, fn) -> None:
    try:
        fn()
    except Exception as e:  # one failing step must not skip the others; class name only, no message
        log.error("tick step %s failed: %s", name, type(e).__name__)


def _update_metrics(now, gw, orc, settings) -> None:
    today = now.date()
    got = setup_view.gather({
        "usage": ("gateway", lambda: gw.usage(today - timedelta(days=USAGE_DAYS), today)),
        "models": ("gateway", lambda: gw.model_info()),
        "global_budget": ("gateway", lambda: gw.global_budget()),
        "inference_key": ("openrouter", lambda: orc.inference_key()),
        "credits": ("openrouter", lambda: orc.credits()),
    }, setup_view.deadline())
    key = got["inference_key"]
    activity = key if isinstance(key, Unavailable) else setup_view.gather(
        {"activity": ("openrouter", lambda: orc.activity(key["hash"]))}, setup_view.deadline())["activity"]
    summary, _ = _summary(got, activity, setup_view.gateway_window(settings), now, "month")
    try:
        switch = killswitch.current_state(gw, orc)
    except Exception:
        switch = None
    expiry = orc.management_key_expiry() or settings.management_key_expires_at
    metrics.update_metrics(summary, switch, store.latest("price_check"), store.latest("smoke_test"), expiry)


def _snapshot_balance(now, orc) -> None:
    last = store.latest("balance")
    if last is not None and now - last.at < SNAPSHOT_EVERY:
        return
    try:
        credits = orc.credits()
    except Unavailable:
        return
    total, used = credits["total_credits"], credits["total_usage"]
    store.log("balance", "loop", True, f"balance ${total - used:.2f}",
              {"balance_usd": total - used, "total_credits": total, "total_usage": used}, at=now)


def _price_check(now, gw, orc) -> None:
    due = datetime.combine(now.date(), CHECK_AT, tzinfo=UTC)
    if now < due:
        return
    last = store.latest("price_check")
    if last is None or last.at < due:
        checks.run_price_check(gw, orc, "loop")


def tick(now, gw, orc, settings) -> None:
    _step("metrics", lambda: _update_metrics(now, gw, orc, settings))
    _step("enforce", lambda: killswitch.enforce(gw))
    _step("balance", lambda: _snapshot_balance(now, orc))
    _step("price_check", lambda: _price_check(now, gw, orc))


def start_loop(app):
    """Starts the daemon thread; returns a stop function that ends it and waits."""
    stop = threading.Event()

    def run():
        while not stop.is_set():
            tick(datetime.now(UTC), app.state.gateway, app.state.openrouter, app.state.settings)
            stop.wait(INTERVAL)

    thread = threading.Thread(target=run, name="tower-loop", daemon=True)
    thread.start()

    def stop_loop():
        stop.set()
        thread.join(timeout=10)

    return stop_loop
