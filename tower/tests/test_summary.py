import time
from datetime import UTC, date, datetime

import pytest

from tower.clients import UsageRow, Unavailable
from tower.summary import (
    cost_summary,
    forecast,
    period_bounds,
    reconcile,
    reconcile_days,
    top_models,
    top_roles,
    usage_tables,
)


def dt(*a):
    return datetime(*a, tzinfo=UTC)


def entry(name, kind, model, order):
    return {
        "model_name": name,
        "litellm_params": {
            "model": f"openrouter/{model}",
            "extra_body": {"provider": {"order": [order]}},
        },
        "model_info": {"rapidselector_kind": kind},
    }


MODELS = [
    entry("chat", "role", "openai/gpt-oss-120b", "deepinfra/bf16"),
    entry("classify", "role", "mistralai/mistral-small-3.2-24b-instruct", "deepinfra/fp8"),
    entry("gpt-oss-120b@deepinfra", "experiment", "openai/gpt-oss-120b", "deepinfra/bf16"),
    entry("cf", "experiment", "google/gemma", "cloudflare"),
]


def row(day, name, calls=1, spend=0.1, alias="k", tin=10, tout=5):
    return UsageRow(day, name, alias, calls, tin, tout, spend)


def test_period_bounds_week_starts_monday():
    b = period_bounds(dt(2026, 11, 4, 12))
    assert b["week"] == (dt(2026, 11, 2), dt(2026, 11, 9))
    assert b["day"] == (dt(2026, 11, 4), dt(2026, 11, 5))
    assert b["month"] == (dt(2026, 11, 1), dt(2026, 12, 1))


def test_period_bounds_sunday_night():
    b = period_bounds(dt(2026, 11, 8, 23, 59))
    assert b["week"][0] == dt(2026, 11, 2)
    assert b["day"][0] == dt(2026, 11, 8)


def test_period_bounds_ignore_local_tz(monkeypatch):
    expected = period_bounds(dt(2026, 11, 8, 23, 59))
    monkeypatch.setenv("TZ", "Europe/Oslo")
    time.tzset()
    try:
        assert period_bounds(dt(2026, 11, 8, 23, 59)) == expected
    finally:
        monkeypatch.undo()
        time.tzset()


def test_forecast_mid_month():
    assert forecast(7.50, dt(2026, 11, 16)) == pytest.approx(15.0)


def test_forecast_on_the_first():
    assert forecast(0.02, dt(2026, 11, 1, 0, 10)) == pytest.approx(0.60)


def test_reconcile_flag_threshold():
    assert not reconcile(7.40, 7.42).flagged
    r = reconcile(1.00, 1.10)
    assert r.flagged and r.diff_usd == pytest.approx(-0.10)
    r = reconcile(10.0, 10.40)
    assert not r.flagged and r.diff_pct == pytest.approx(-100 * 0.4 / 10.4)
    assert reconcile(0.0, 0.0).diff_pct is None


def test_reconcile_days_maps_hosts():
    rows = [
        row(date(2026, 11, 3), "chat", spend=0.50),
        row(date(2026, 11, 3), "gpt-oss-120b@deepinfra", spend=0.25),
        row(date(2026, 11, 3), "classify", spend=1.00),
        row(date(2026, 11, 4), "chat", spend=0.31),
    ]
    activity = [
        {"date": "2026-11-03", "model": "openai/gpt-oss-120b", "provider_name": "DeepInfra", "usage": 0.75},
        {"date": "2026-11-03", "model": "mistralai/mistral-small-3.2-24b-instruct", "provider_name": "DeepInfra", "usage": 1.50},
    ]
    lines = reconcile_days(rows, activity, MODELS, 0.30, date(2026, 11, 4))
    by = {(ln.day, ln.model, ln.host): ln for ln in lines}
    a = by[(date(2026, 11, 3), "openai/gpt-oss-120b", "deepinfra")]
    assert (a.gateway_usd, a.openrouter_usd, a.flagged) == (pytest.approx(0.75), 0.75, False)
    b = by[(date(2026, 11, 3), "mistralai/mistral-small-3.2-24b-instruct", "deepinfra")]
    assert b.flagged
    today = [ln for ln in lines if ln.day == date(2026, 11, 4)]
    assert len(today) == 1 and today[0].gateway_usd == pytest.approx(0.31)
    assert today[0].openrouter_usd == 0.30 and not today[0].flagged


def test_top_models_counts_role_and_experiment_together():
    rows = [row(date(2026, 11, 3), "chat", calls=3, spend=0.3),
            row(date(2026, 11, 3), "gpt-oss-120b@deepinfra", calls=2, spend=0.2),
            row(date(2026, 11, 3), "classify", calls=1, spend=0.9)]
    out = top_models(rows, MODELS, dt(2026, 11, 1), dt(2026, 12, 1))
    d = {r.label: r for r in out}
    assert d["openai/gpt-oss-120b@deepinfra"].calls == 5
    assert d["openai/gpt-oss-120b@deepinfra"].spend_usd == pytest.approx(0.5)
    assert out[0].label.startswith("mistralai/")
    roles = top_roles(rows, MODELS, dt(2026, 11, 1), dt(2026, 12, 1))
    assert {r.label for r in roles} == {"chat", "classify"}


def test_usage_tables_split_and_periods():
    now = dt(2026, 11, 4, 12)
    rows = [row(date(2026, 11, 4), "chat", spend=0.1), row(date(2026, 11, 2), "chat", spend=0.2),
            row(date(2026, 11, 1), "cf", spend=0.3, alias="exp"), row(date(2026, 10, 31), "chat")]
    t = usage_tables(rows, MODELS, now)
    chat = next(x for x in t.roles if x.label == "chat")
    assert (chat.day.calls, chat.week.calls, chat.month.calls) == (1, 2, 2)
    assert [x.label for x in t.experiments] == ["cf"]
    assert {x.label for x in t.keys} == {"k", "exp"}


def _kw(**over):
    base = dict(
        inference_key={"limit": 35.0, "limit_remaining": 27.6, "limit_reset": "monthly",
                       "usage_daily": 0.31, "usage_weekly": 2.10, "usage_monthly": 7.42},
        credits={"total_credits": 20.0, "total_usage": 7.4},
        usage=[row(date(2026, 11, 3), "chat", spend=7.40)],
        models=MODELS, global_budget=32.0, global_window="30d",
        price_check=None, smoke_test=None, now=dt(2026, 11, 16),
    )
    base.update(over)
    return base


def test_summary_complete():
    s = cost_summary(**_kw())
    assert s.balance_usd == pytest.approx(12.6)
    assert s.spend_month_usd == 7.42 and s.limit_usd == 35.0
    assert s.resets_agree is True and s.next_reset == dt(2026, 12, 1)
    assert s.reconciliation.gateway_usd == pytest.approx(7.40)
    assert s.missing == [] and s.forecast_usd == pytest.approx(7.42 / 15 * 30)


def test_summary_with_openrouter_down():
    s = cost_summary(**_kw(inference_key=Unavailable("openrouter", "HTTP 500"),
                           credits=Unavailable("openrouter", "HTTP 500")))
    assert s.balance_usd is None and s.spend_month_usd is None
    assert s.missing == ["openrouter"]
    assert s.reconciliation is None and s.forecast_usd is None
    assert s.global_budget_usd == 32.0 and s.top_roles


def test_summary_with_gateway_down():
    s = cost_summary(**_kw(usage=Unavailable("gateway", "x"), models=Unavailable("gateway", "x"),
                           global_budget=Unavailable("gateway", "x")))
    assert s.missing == ["gateway"] and s.top_roles is None and s.balance_usd == pytest.approx(12.6)


def test_resets_mismatch_shown():
    s = cost_summary(**_kw(inference_key={**_kw()["inference_key"], "limit_reset": "weekly"}))
    assert s.resets_agree is False
    assert (s.key_reset, s.gateway_window) == ("weekly", "30d")
