"""Prometheus metrics for /metrics: values only, from a dedicated registry.

A gauge whose value is unknown is left out, not set to 0."""
import threading
from datetime import datetime

from prometheus_client import CollectorRegistry
from prometheus_client.core import GaugeMetricFamily

PREFIX = "rapidselector_"
HELP = {
    "openrouter_balance_usd": "OpenRouter prepaid balance (credits minus usage)",
    "key_limit_usd": "Credit limit on the OpenRouter inference key",
    "key_limit_remaining_usd": "Remaining credit limit on the OpenRouter inference key",
    "key_usage_usd": "Spend of the OpenRouter inference key",
    "reconciliation_diff_usd": "Gateway month spend minus OpenRouter month spend",
    "reconciliation_flagged": "1 when the reconciliation gap is flagged",
    "kill_switch_level": "Kill switch level 0, 1 or 2; -1 when unknown",
    "price_check_ok": "1 when the latest price check passed",
    "price_check_last_run_timestamp_seconds": "When the latest price check ran",
    "smoke_test_ok": "1 when the latest smoke test passed",
    "management_key_expires_timestamp_seconds": "When the OpenRouter management key expires",
    "upstream_ok": "1 when the source answered",
    "loop_last_tick_timestamp_seconds": "When the background loop last finished a tick",
}
LABELS = {"key_usage_usd": "period", "upstream_ok": "source"}


class _Collector:
    def __init__(self):
        self._lock = threading.Lock()
        self._values: dict[str, dict] = {}  # name -> {label value or None: float}
        self._tick: float | None = None  # kept apart: a failed metrics step must not hide the heartbeat

    def replace(self, values: dict[str, dict]) -> None:
        with self._lock:
            self._values = values

    def tick(self, timestamp: float) -> None:
        with self._lock:
            self._tick = timestamp

    def collect(self):
        with self._lock:
            values = {name: dict(v) for name, v in self._values.items()}
            if self._tick is not None:
                values["loop_last_tick_timestamp_seconds"] = {None: self._tick}
        for name, series in values.items():
            label = LABELS.get(name)
            family = GaugeMetricFamily(PREFIX + name, HELP[name], labels=[label] if label else [])
            for key, value in series.items():
                family.add_metric([key] if label else [], value)
            yield family


_collector = _Collector()
REGISTRY = CollectorRegistry()
REGISTRY.register(_collector)


def _flag(value) -> float | None:
    return None if value is None else (1.0 if value else 0.0)


def mark_tick(now: datetime) -> None:
    _collector.tick(now.timestamp())


def update_metrics(summary, switch, latest_price, latest_smoke, expiry: datetime | None) -> None:
    """summary: a CostSummary; switch: a SwitchState or None; latest_*: LogEntry or None."""
    v: dict[str, dict] = {}

    def put(name, value, key=None):
        if value is not None:
            v.setdefault(name, {})[key] = float(value)

    put("openrouter_balance_usd", summary.balance_usd)
    put("key_limit_usd", summary.limit_usd)
    put("key_limit_remaining_usd", summary.limit_remaining_usd)
    put("key_usage_usd", summary.spend_day_usd, "day")
    put("key_usage_usd", summary.spend_week_usd, "week")
    put("key_usage_usd", summary.spend_month_usd, "month")
    if summary.reconciliation is not None:
        put("reconciliation_diff_usd", summary.reconciliation.diff_usd)
        put("reconciliation_flagged", _flag(summary.reconciliation.flagged))
    level = switch.level if switch is not None else None
    put("kill_switch_level", -1 if level is None else level)
    if latest_price is not None:
        put("price_check_ok", _flag(latest_price.ok))
        put("price_check_last_run_timestamp_seconds", latest_price.at.timestamp())
    if latest_smoke is not None:
        put("smoke_test_ok", _flag(latest_smoke.ok))
    if expiry is not None:
        put("management_key_expires_timestamp_seconds", expiry.timestamp())
    for source in ("gateway", "openrouter"):
        put("upstream_ok", source not in summary.missing, source)
    _collector.replace(v)
