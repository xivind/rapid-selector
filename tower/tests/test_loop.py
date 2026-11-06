import threading
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from tower import checks, killswitch, loop, metrics, store
from tower.app import create_app
from tower.clients import Unavailable
from tower.settings import load_settings
from test_pages import ENV, FakeGateway, FakeOpenRouter


@pytest.fixture
def db(tmp_path):
    store.init_db(tmp_path / "tower.db")
    yield
    store.db.obj.close()


@pytest.fixture
def price_runs(monkeypatch):
    runs = []

    def fake(gw, orc, actor):
        runs.append(actor)
        store.log("price_check", actor, True, "all prices match", {})
        return []

    monkeypatch.setattr(checks, "run_price_check", fake)
    return runs


def at(h, m):
    return datetime(2026, 11, 6, h, m, tzinfo=UTC)


class Down:
    def __getattr__(self, name):
        def call(*a, **k):
            raise Unavailable("x", "down")
        return call

    def own_hash(self):
        return "h"

    def management_key_expiry(self):
        return None


def test_tick_runs_price_check_once_after_0630(db, price_runs):
    settings = load_settings(ENV)
    gw, orc = FakeGateway(), FakeOpenRouter()
    loop.tick(at(5, 0), gw, orc, settings)
    assert price_runs == []
    loop.tick(at(6, 31), gw, orc, settings)
    assert price_runs == ["loop"]
    loop.tick(at(6, 32), gw, orc, settings)
    assert price_runs == ["loop"]


def test_tick_snapshots_balance_hourly(db, price_runs):
    settings = load_settings(ENV)
    gw, orc = FakeGateway(), FakeOpenRouter()
    loop.tick(at(7, 0), gw, orc, settings)
    loop.tick(at(7, 30), gw, orc, settings)
    assert store.LogEntry.select().where(store.LogEntry.kind == "balance").count() == 1
    loop.tick(at(8, 1), gw, orc, settings)
    entries = list(store.LogEntry.select().where(store.LogEntry.kind == "balance"))
    assert len(entries) == 2
    assert entries[0].actor == "loop"
    assert '"balance_usd": 12.6' in entries[0].detail


def test_tick_survives_unavailable(db, price_runs):
    loop.tick(at(7, 0), Down(), Down(), load_settings(ENV))
    assert store.latest("balance") is None
    assert metrics.REGISTRY.get_sample_value("rapidselector_upstream_ok", {"source": "gateway"}) == 0
    assert metrics.REGISTRY.get_sample_value("rapidselector_upstream_ok", {"source": "openrouter"}) == 0
    assert metrics.REGISTRY.get_sample_value("rapidselector_kill_switch_level") == -1


def test_tick_one_failing_step_does_not_skip_the_rest(db, price_runs, monkeypatch):
    def boom(gw):
        raise RuntimeError("sk-gw-secret")

    monkeypatch.setattr(killswitch, "enforce", boom)
    loop.tick(at(7, 0), FakeGateway(), FakeOpenRouter(), load_settings(ENV))
    assert store.latest("balance") is not None
    assert price_runs == ["loop"]


def test_lifespan_starts_and_stops_the_loop(db, monkeypatch):
    ticks = threading.Event()
    monkeypatch.setattr(loop, "tick", lambda *a: ticks.set())
    app = create_app(load_settings(ENV), gateway=FakeGateway(), openrouter=FakeOpenRouter())
    before = {t.name for t in threading.enumerate()}
    assert "tower-loop" not in before
    with TestClient(app):
        assert ticks.wait(5)
        assert any(t.name == "tower-loop" and t.is_alive() for t in threading.enumerate())
    assert not any(t.name == "tower-loop" for t in threading.enumerate())


def test_tick_calls_enforce_with_the_gateway(db, price_runs, monkeypatch):
    calls = []
    monkeypatch.setattr(killswitch, "enforce", lambda gw: calls.append(gw) or [])
    gw = FakeGateway()
    loop.tick(at(7, 0), gw, FakeOpenRouter(), load_settings(ENV))
    assert calls == [gw]


def test_tick_sets_the_heartbeat_even_when_steps_fail(db, price_runs):
    loop.tick(at(7, 0), Down(), Down(), load_settings(ENV))
    assert metrics.REGISTRY.get_sample_value("rapidselector_loop_last_tick_timestamp_seconds") == at(7, 0).timestamp()
    loop.tick(at(7, 1), FakeGateway(), FakeOpenRouter(), load_settings(ENV))
    assert metrics.REGISTRY.get_sample_value("rapidselector_loop_last_tick_timestamp_seconds") == at(7, 1).timestamp()
