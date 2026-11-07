from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

from tower.clients import GatewayKey, Unavailable
from tower.killswitch import SwitchState, read_state
from tower.status import panel_lights, tab_lights
from tower.summary import reconcile

NOW = datetime(2026, 11, 7, 12, 0, tzinfo=UTC)


def state(level=0, by_tower=(), outside=(), disabled=False, gateway_read=True, problems=()):
    return SwitchState(level=level, outside_tower=bool(outside), level1_complete=bool(by_tower or outside),
                       blocked_by_tower=list(by_tower), blocked_outside=list(outside),
                       openrouter_disabled=disabled, problems=list(problems), gateway_read=gateway_read)


def check(ok=True, at=NOW - timedelta(hours=5, minutes=30)):
    return SimpleNamespace(ok=ok, at=at)


def lights(s, price=None, recon=None):
    got = panel_lights(s, check() if price is None else price, recon, NOW)
    return {k: (v.colour, v.word) for k, v in got.items()}


def test_read_state_marks_gateway_unread():
    down = read_state(Unavailable("gateway", "ConnectError"), {"disabled": False}, set(), False, "own")
    up = read_state([GatewayKey("own", "tower", None, False)], {"disabled": False}, set(), False, "own")
    assert down.gateway_read is False and up.gateway_read is True


def test_lights_all_clear():
    got = lights(state(), recon=reconcile(7.40, 7.40))
    assert got == {"gateway_keys": ("go", "open"), "openrouter_key": ("go", "enabled"),
                   "price_check": ("go", "ok, 06:30"), "reconciliation": ("go", "in step")}


def test_lights_level1_by_tower():
    assert lights(state(1, by_tower=["a", "b"]))["gateway_keys"] == ("stop", "2 blocked by tower")


def test_lights_blocked_outside():
    assert lights(state(1, outside=["x"]))["gateway_keys"] == ("stop", "1 blocked outside tower")


def test_lights_gateway_down():
    got = lights(state(None, gateway_read=False), recon=Unavailable("gateway", "x"))
    assert got["gateway_keys"] == ("caution", "cannot read the gateway")
    assert got["reconciliation"] == ("off", "no figures")


def test_lights_openrouter_down():
    got = lights(state(None, disabled=None), recon=Unavailable("openrouter", "x"))
    assert got["openrouter_key"] == ("caution", "unknown")
    assert got["reconciliation"][0] == "off"
    assert lights(state(2, disabled=True))["openrouter_key"] == ("stop", "disabled")


def test_price_light_not_run_stale_failed_ok():
    assert panel_lights(state(), None, None, NOW)["price_check"].colour == "off"
    assert panel_lights(state(), None, None, NOW)["price_check"].word == "not run yet"
    stale = lights(state(), price=check(at=NOW - timedelta(hours=27)))["price_check"]
    assert stale == ("caution", "stale, last 6 Nov 09:00")
    assert lights(state(), price=check(ok=False))["price_check"] == ("stop", "failed, 7 Nov 06:30")
    assert lights(state())["price_check"] == ("go", "ok, 06:30")


def test_reconciliation_light_none_flagged_in_step_apart():
    assert lights(state(), recon=None)["reconciliation"] == ("off", "no figures")
    assert lights(state(), recon=reconcile(7.40, 6.00))["reconciliation"] == ("stop", "$1.40 apart")
    assert lights(state(), recon=reconcile(7.405, 7.40))["reconciliation"] == ("go", "in step")
    assert lights(state(), recon=reconcile(7.44, 7.40))["reconciliation"] == ("go", "$0.04 apart")


def view(models=None, teams=None, or_key=None, days_left=200, secrets=None):
    return {
        "models": models if models is not None else [{"name": "chat", "price_check": "ok"}],
        "teams_and_keys": teams if teams is not None else [
            {"id": "t1", "alias": "experiments", "budget": 24.0, "spend": 5.0, "blocked": False,
             "keys": [{"alias": "chat", "blocked": False}]}],
        "openrouter_key": or_key if or_key is not None else {"disabled": False},
        "management_key": {"days_left": days_left},
        "secrets": secrets if secrets is not None else [("TOWER_PASSWORD", "set")],
    }


def colours(v):
    return {k: (x.colour if x else None) for k, x in tab_lights(v, NOW).items()}


def test_tab_lights_all_green_and_no_light_for_gateway_and_webui():
    assert colours(view()) == {"models": "go", "teams_and_keys": "go", "openrouter": "go",
                               "secrets": "go", "gateway": None, "open_webui": None}


def test_tab_lights_models():
    assert colours(view(models=[{"name": "a", "price_check": None}]))["models"] == "off"
    bad = [{"name": "a", "price_check": "ok"}, {"name": "b", "price_check": "price differs"}]
    assert colours(view(models=bad))["models"] == "stop"
    v = view()
    v["models"] = None
    assert colours(v)["models"] == "off"


def test_tab_lights_teams():
    def team(spend, blocked=False, key_blocked=False):
        return [{"id": "t", "alias": "x", "budget": 10.0, "spend": spend, "blocked": blocked,
                 "keys": [{"alias": "k", "blocked": key_blocked}]}]
    assert colours(view(teams=team(8.5)))["teams_and_keys"] == "caution"  # 15% left
    assert colours(view(teams=team(9.5)))["teams_and_keys"] == "stop"  # 5% left
    assert colours(view(teams=team(1.0, blocked=True)))["teams_and_keys"] == "stop"
    assert colours(view(teams=team(1.0, key_blocked=True)))["teams_and_keys"] == "stop"
    no_team = [{"id": None, "alias": "no team", "budget": None, "spend": None, "blocked": False,
                "keys": [{"alias": "k", "blocked": False}]}]
    assert colours(view(teams=no_team))["teams_and_keys"] == "go"
    v = view()
    v["teams_and_keys"] = None
    assert colours(v)["teams_and_keys"] == "off"


def test_tab_lights_openrouter():
    assert colours(view(or_key={"disabled": True}))["openrouter"] == "stop"
    assert colours(view(days_left=-1))["openrouter"] == "stop"
    assert colours(view(days_left=None))["openrouter"] == "caution"
    assert colours(view(days_left=29))["openrouter"] == "caution"
    v = view()
    v["openrouter_key"] = None
    assert colours(v)["openrouter"] == "off"


def test_tab_lights_secrets():
    assert colours(view(secrets=[("A", "set"), ("B", "not set")]))["secrets"] == "stop"


def test_price_light_failed_stays_red_when_stale():
    old_fail = check(ok=False, at=NOW - timedelta(hours=27))
    assert lights(state(), price=old_fail)["price_check"] == ("stop", "failed, last 6 Nov 09:00")


def test_tab_lights_models_caution_when_one_not_checked():
    some = [{"name": "a", "price_check": "ok"}, {"name": "new", "price_check": None}]
    assert colours(view(models=some))["models"] == "caution"
