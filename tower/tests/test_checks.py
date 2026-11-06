import copy
import hashlib
import json
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from tower import store
from tower.app import create_app
from tower.checks import (PriceResult, SmokePlan, check_prices, plan_smoke, run_price_check,
                          run_smoke)
from tower.clients import Unavailable
from tower.killswitch import SwitchState
from tower.settings import load_settings

SAMPLES = Path(__file__).parent / "samples"
MODELS = json.loads((SAMPLES / "gateway-model-info.json").read_text())["data"]
ENDPOINTS = json.loads((SAMPLES / "zdr.json").read_text())["data"]
SMOKE_KEY = "sk-smoke-secret"
ENV = {
    "TOWER_PASSWORD": "pw-secret", "TOWER_SESSION_SECRET": "session-secret",
    "OPENROUTER_MANAGEMENT_KEY": "mgmt-secret", "TOWER_GATEWAY_KEY": "sk-gw-secret",
    "KEY_SMOKE_TEST": SMOKE_KEY,
}
CLEAR = SwitchState(0, False, False, [], [], False, [])


def endpoint_for(model_name):
    entry = next(m for m in MODELS if m["model_name"] == model_name)
    model = entry["litellm_params"]["model"].removeprefix("openrouter/")
    slug = entry["litellm_params"]["extra_body"]["provider"]["order"][0]
    return next(e for e in ENDPOINTS if e["model_id"] == model and e["tag"] == slug)


def run_with(endpoints=ENDPOINTS, models=MODELS):
    return {r.name: r for r in check_prices(models, endpoints)}


def changed(name, **fields):
    eps = copy.deepcopy(ENDPOINTS)
    target = endpoint_for(name)
    for e in eps:
        if e["model_id"] == target["model_id"] and e["tag"] == target["tag"]:
            e.update(fields)
    return eps


def test_price_all_ok():
    results = check_prices(MODELS, ENDPOINTS)
    assert len(results) == 11
    assert all(r.ok for r in results), [r for r in results if not r.ok]
    assert results[0] == PriceResult("classify", "deepinfra/fp8", True, "")


def test_price_no_endpoint():
    eps = [e for e in ENDPOINTS if e is not endpoint_for("classify")]
    r = run_with(eps)["classify"]
    assert not r.ok
    assert r.reason == "no zero data retention endpoint deepinfra/fp8 for mistralai/mistral-small-3.2-24b-instruct"


def test_price_flex_tier():
    r = run_with(changed("classify", service_tier="flex"))["classify"]
    assert (r.ok, r.reason) == (False, "flex tier")


def test_price_safety_retention():
    r = run_with(changed("classify", safety_retention=True))["classify"]
    assert (r.ok, r.reason) == (False, "uses Safety Retention, not zero data retention")


def test_price_differs():
    r = run_with(changed("classify", pricing={"prompt": "0.0000001", "completion": "0.0000002"}))["classify"]
    assert not r.ok
    assert r.reason == "price is now 0.0000001 / 0.0000002 per token, configured 7.5e-08 / 2e-07"


def test_price_reads_what_the_gateway_runs():
    # The file is untouched and matches the endpoints; the running gateway has another price.
    models = copy.deepcopy(MODELS)
    models[0]["model_info"]["output_cost_per_token"] = 9e-07
    results = run_with(models=models)
    assert not results["classify"].ok
    assert "9e-07" in results["classify"].reason
    assert results["summarise"].ok


def test_price_falls_back_to_litellm_params():
    models = copy.deepcopy(MODELS)
    del models[0]["model_info"]["input_cost_per_token"]
    del models[0]["model_info"]["output_cost_per_token"]
    assert run_with(models=models)["classify"].ok


def test_price_missing():
    models = copy.deepcopy(MODELS)
    for part in ("model_info", "litellm_params"):
        models[0][part].pop("input_cost_per_token")
    r = run_with(models=models)["classify"]
    assert (r.ok, r.reason) == (False, "missing price in the config")


def priced(name, i, o, kind="role", reasoning=False):
    return {"model_name": name, "model_info": {"rapidselector_kind": kind, "reasoning": reasoning,
                                              "input_cost_per_token": i, "output_cost_per_token": o}}


def test_worst_case():
    plan = plan_smoke([priced("a", 1e-7, 2e-7), priced("b", 3e-7, 4e-7)], "roles")
    assert plan.names == [("a", False), ("b", False)]
    assert plan.worst_case_usd == pytest.approx(50 * 1e-7 + 256 * 2e-7 + 50 * 3e-7 + 256 * 4e-7)


def test_plan_scope_and_unique_names():
    assert [n for n, _ in plan_smoke(MODELS, "roles").names] == ["classify", "summarise", "code", "chat"]
    assert len(plan_smoke(MODELS, "all").names) == 11
    assert plan_smoke(MODELS + MODELS, "all").names == plan_smoke(MODELS, "all").names
    assert dict(plan_smoke(MODELS, "roles").names)["chat"] is True


# run_smoke

class Recorder:
    """A mock transport: records requests, answers 200 with a cost unless told otherwise."""

    def __init__(self, cost="0.00001", chat_status=200, gpt4o=400, passthrough=401):
        self.cost, self.chat_status, self.gpt4o, self.passthrough = cost, chat_status, gpt4o, passthrough
        self.requests = []

    def __call__(self, request):
        body = json.loads(request.content)
        self.requests.append((request.url.path, body, request.headers["authorization"]))
        if request.url.path.startswith("/openrouter"):
            return httpx.Response(self.passthrough)
        if body["model"] == "openai/gpt-4o":
            return httpx.Response(self.gpt4o)
        headers = {} if self.cost is None else {"x-litellm-response-cost": self.cost}
        return httpx.Response(self.chat_status, headers=headers, json={})

    def client(self):
        return httpx.Client(transport=httpx.MockTransport(self))


PLAN = SmokePlan([("classify", False), ("chat", True)], 0.001)


def smoke(rec, switch=CLEAR, budget=1.0):
    return run_smoke(PLAN, switch, budget, "http://gw:4000", SMOKE_KEY, rec.client())


def test_smoke_ok():
    rec = Recorder()
    r = smoke(rec)
    assert r.ok and r.refused_reason is None
    assert r.rows == [("classify", 200, 1e-5), ("chat", 200, 1e-5)]
    assert r.refusals == [("openai/gpt-4o", 400), ("/openrouter/v1/chat/completions", 401)]
    assert r.total_usd == pytest.approx(2e-5)
    assert all(a == f"Bearer {SMOKE_KEY}" for _, _, a in rec.requests)
    assert rec.requests[0][1] == {"model": "classify", "max_tokens": 256,
                                  "messages": [{"role": "user", "content": "Reply with the word ok."}]}


def test_reasoning_gets_low_effort():
    rec = Recorder()
    smoke(rec)
    bodies = {b["model"]: b for _, b, _ in rec.requests}
    assert bodies["chat"]["reasoning_effort"] == "low"
    assert "reasoning_effort" not in bodies["classify"]


@pytest.mark.parametrize("level", [1, 2, None])
def test_smoke_refused_while_level1_engaged(level):
    rec = Recorder()
    r = smoke(rec, SwitchState(level, False, False, [], [], False, []))
    assert rec.requests == []
    assert not r.ok and r.rows == [] and r.refusals == [] and r.total_usd == 0
    assert r.refused_reason


def test_smoke_refused_when_budget_too_low():
    rec = Recorder()
    r = smoke(rec, budget=0.0005)
    assert rec.requests == []
    assert not r.ok and "budget" in r.refused_reason


def test_smoke_no_budget_is_allowed():
    assert smoke(Recorder(), budget=None).ok


def test_smoke_zero_cost_fails():
    r = smoke(Recorder(cost="0"))
    assert not r.ok and r.refused_reason is None and r.total_usd == 0
    assert smoke(Recorder(cost=None)).ok is False


def test_smoke_http_error_fails():
    r = smoke(Recorder(chat_status=500))
    assert not r.ok
    assert r.rows[0][1] == 500


def test_smoke_probe_not_refused_fails():
    assert not smoke(Recorder(gpt4o=200)).ok
    assert not smoke(Recorder(passthrough=200)).ok
    assert not smoke(Recorder(passthrough=404)).ok  # only 401 or 403 counts
    assert smoke(Recorder(passthrough=403)).ok


def test_smoke_connection_error_fails():
    def boom(request):
        raise httpx.ConnectError("down")
    r = run_smoke(PLAN, CLEAR, 1.0, "http://gw:4000", SMOKE_KEY, httpx.Client(transport=httpx.MockTransport(boom)))
    assert not r.ok and r.rows[0] == ("classify", 0, 0.0)


# routes and logging

class FakeGateway:
    def __init__(self, max_budget=1.0, spend=0.0, key_error=None):
        self.max_budget, self.spend, self.key_error = max_budget, spend, key_error
        self.key_asked = []

    def own_hash(self):
        return "own"

    def keys(self):
        return []

    def model_info(self):
        return MODELS

    def key(self, h):
        self.key_asked.append(h)
        if self.key_error:
            raise self.key_error
        return {"key": h, "info": {"max_budget": self.max_budget, "spend": self.spend}}


class FakeOpenRouter:
    def __init__(self, endpoints=ENDPOINTS):
        self.endpoints = endpoints

    def inference_key(self):
        return {"hash": "h", "disabled": False}

    def zdr_endpoints(self):
        if self.endpoints is None:
            raise Unavailable("openrouter", "HTTP 503")
        return self.endpoints


@pytest.fixture
def db(tmp_path):
    store.init_db(tmp_path / "tower.db")
    yield tmp_path
    store.db.close()


def browser(gw, orc=None):
    c = TestClient(create_app(load_settings(ENV), gateway=gw, openrouter=orc or FakeOpenRouter(),
                              start_loop=False), follow_redirects=False)
    c.post("/login", data={"password": "pw-secret"})
    return c


def assert_no_secret(entry):
    text = entry.summary + entry.detail
    for secret in ENV.values():
        assert secret not in text


def test_run_price_check_logs(db):
    results = run_price_check(FakeGateway(), FakeOpenRouter(), "loop")
    entry = store.latest("price_check")
    assert entry.ok is True and entry.actor == "loop"
    assert len(json.loads(entry.detail)["results"]) == len(results) == 11
    run_price_check(FakeGateway(), FakeOpenRouter(changed("classify", service_tier="flex")), "owner")
    entry = store.latest("price_check")
    assert entry.ok is False
    assert json.loads(entry.detail)["results"]["classify"] == "flex tier"


def test_price_route(db):
    c = browser(FakeGateway())
    r = c.post("/checks/price")
    assert r.status_code == 200
    assert "classify" in r.text and "deepinfra/fp8" in r.text
    assert store.latest("price_check").actor == "owner"


def test_price_route_unavailable_is_a_result(db):
    r = browser(FakeGateway(), FakeOpenRouter(None)).post("/checks/price")
    assert r.status_code == 200
    assert "openrouter unavailable" in r.text
    assert store.latest("price_check").ok is False


def test_price_route_needs_login(db):
    c = TestClient(create_app(load_settings(ENV), gateway=FakeGateway(), openrouter=FakeOpenRouter(),
                              start_loop=False), follow_redirects=False)
    assert c.post("/checks/price").status_code == 401


def test_smoke_confirm_page(db):
    r = browser(FakeGateway()).get("/checks/smoke?scope=roles")
    assert r.status_code == 200
    for name in ("classify", "summarise", "code", "chat"):
        assert name in r.text
    assert "worst case" in r.text.lower() and 'name="confirm"' in r.text
    assert browser(FakeGateway()).get("/checks/smoke?scope=bogus").status_code == 422


def test_smoke_post_needs_confirm(db):
    c = browser(FakeGateway())
    r = c.post("/checks/smoke", data={"scope": "roles"})
    assert r.status_code == 200 and "confirm" in r.text.lower()
    assert store.latest("smoke_test") is None


def test_smoke_post_refused_while_level1_engaged(db, monkeypatch):
    import tower.checks as checks
    monkeypatch.setattr(checks, "current_state",
                        lambda gw, orc, fresh=False: SwitchState(1, False, True, ["a"], [], False, []))
    c = browser(FakeGateway())
    r = c.post("/checks/smoke", data={"scope": "roles", "confirm": "yes"})
    assert r.status_code == 200 and "refused" in r.text.lower()
    entry = store.latest("smoke_test")
    detail = json.loads(entry.detail)
    assert entry.ok is False and detail["rows"] == [] and detail["refused_reason"]
    assert_no_secret(entry)


def test_smoke_post_refused_when_key_unreadable(db):
    c = browser(FakeGateway(key_error=Unavailable("gateway", "HTTP 503")))
    r = c.post("/checks/smoke", data={"scope": "roles", "confirm": "yes"})
    assert r.status_code == 200 and "gateway unavailable" in r.text
    detail = json.loads(store.latest("smoke_test").detail)
    assert detail["rows"] == [] and "gateway unavailable" in detail["refused_reason"]


def test_smoke_post_refused_when_budget_spent(db):
    gw = FakeGateway(max_budget=0.001, spend=0.0009)
    r = browser(gw).post("/checks/smoke", data={"scope": "roles", "confirm": "yes"})
    assert "budget" in json.loads(store.latest("smoke_test").detail)["refused_reason"]
    # The key is asked for by the hash of the key, never the key itself.
    assert gw.key_asked == [hashlib.sha256(SMOKE_KEY.encode()).hexdigest()]
    assert SMOKE_KEY not in r.text


def test_smoke_post_runs_and_logs(db, monkeypatch):
    import tower.checks as checks
    rec = Recorder()
    real = httpx.Client
    monkeypatch.setattr(checks.httpx, "Client", lambda **kw: real(transport=httpx.MockTransport(rec)))
    monkeypatch.setattr(checks, "current_state", lambda gw, orc, fresh=False: CLEAR)
    r = browser(FakeGateway()).post("/checks/smoke", data={"scope": "roles", "confirm": "yes"})
    assert r.status_code == 200
    entry = store.latest("smoke_test")
    detail = json.loads(entry.detail)
    assert entry.ok is True and entry.actor == "owner"
    assert [row[0] for row in detail["rows"]] == ["classify", "summarise", "code", "chat"]
    assert detail["total_usd"] == pytest.approx(4e-5)
    assert detail["refused_reason"] is None
    assert_no_secret(entry)
    assert SMOKE_KEY not in r.text


class Broken(FakeGateway):
    def model_info(self):
        raise KeyError("data")  # a malformed answer, not Unavailable


def test_check_routes_render_any_source_error(db):
    c = browser(Broken())
    for method, path, data in (("get", "/checks/smoke?scope=roles", None),
                               ("post", "/checks/smoke", {"scope": "roles", "confirm": "yes"}),
                               ("post", "/checks/price", None)):
        r = getattr(c, method)(path, data=data) if data else getattr(c, method)(path)
        assert r.status_code == 200, path
        assert ("price check failed: KeyError" if path == "/checks/price" else "gateway unavailable: KeyError") in r.text, path
    assert store.latest("price_check").ok is False


def test_smoke_post_refused_when_key_read_raises_anything(db):
    c = browser(FakeGateway(key_error=ValueError("odd answer")))
    r = c.post("/checks/smoke", data={"scope": "roles", "confirm": "yes"})
    assert r.status_code == 200 and "Refused, nothing spent" in r.text
    assert json.loads(store.latest("smoke_test").detail)["rows"] == []
