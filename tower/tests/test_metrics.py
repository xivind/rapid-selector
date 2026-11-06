from datetime import UTC, datetime
from types import SimpleNamespace

from fastapi.testclient import TestClient

from tower import metrics, store
from tower.app import create_app
from tower.killswitch import SwitchState
from tower.settings import load_settings
from tower.summary import Reconciliation
from test_pages import ENV, FakeGateway, FakeOpenRouter

NOW = datetime(2026, 11, 6, 12, 0, tzinfo=UTC)


def summary(**kw):
    base = dict(balance_usd=12.6, limit_usd=35.0, limit_remaining_usd=27.6, spend_day_usd=0.31,
                spend_week_usd=2.1, spend_month_usd=7.4,
                reconciliation=Reconciliation(7.5, 7.4, 0.1, 1.3, False), missing=[])
    return SimpleNamespace(**{**base, **kw})


def switch(level):
    return SwitchState(level, False, True, [], [], False, [])


def entry(ok):
    return SimpleNamespace(ok=ok, at=NOW)


def value(name, **labels):
    return metrics.REGISTRY.get_sample_value("rapidselector_" + name, labels)


def test_metrics_names_and_values():
    metrics.update_metrics(summary(missing=["gateway"]), switch(1), entry(True), entry(False), NOW)
    assert value("openrouter_balance_usd") == 12.6
    assert value("key_limit_usd") == 35.0
    assert value("key_limit_remaining_usd") == 27.6
    assert value("key_usage_usd", period="day") == 0.31
    assert value("key_usage_usd", period="week") == 2.1
    assert value("key_usage_usd", period="month") == 7.4
    assert value("reconciliation_diff_usd") == 0.1
    assert value("reconciliation_flagged") == 0
    assert value("kill_switch_level") == 1
    assert value("price_check_ok") == 1
    assert value("price_check_last_run_timestamp_seconds") == NOW.timestamp()
    assert value("smoke_test_ok") == 0
    assert value("management_key_expires_timestamp_seconds") == NOW.timestamp()
    assert value("upstream_ok", source="gateway") == 0
    assert value("upstream_ok", source="openrouter") == 1


def test_metrics_unknown_switch_is_minus_one():
    metrics.update_metrics(summary(balance_usd=None, reconciliation=None), switch(None), None, None, None)
    assert value("kill_switch_level") == -1
    assert value("openrouter_balance_usd") is None
    assert value("price_check_ok") is None
    assert value("smoke_test_ok") is None
    assert value("management_key_expires_timestamp_seconds") is None


def test_metrics_no_secret():
    settings = load_settings(ENV)
    metrics.update_metrics(summary(), switch(0), entry(True), entry(True), NOW)
    r = TestClient(create_app(settings, gateway=FakeGateway(), openrouter=FakeOpenRouter(),
                              start_loop=False), follow_redirects=False).get("/metrics")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/plain")
    assert "rapidselector_kill_switch_level 0.0" in r.text
    for secret in settings.secret_values():
        assert secret not in r.text
