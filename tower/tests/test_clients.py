import hashlib
import json
import logging
from datetime import date
from pathlib import Path

import httpx
import pytest

from tower.clients import GatewayClient, OpenRouterClient, Unavailable

SAMPLES = Path(__file__).parent / "samples"
KEY = "sk-secret-123"


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def gateway(handler, clock=None):
    http = httpx.Client(transport=httpx.MockTransport(handler))
    return GatewayClient("http://gw", KEY, http, clock=clock or Clock())


def openrouter(handler, name="rapidselector-gateway"):
    http = httpx.Client(transport=httpx.MockTransport(handler))
    return OpenRouterClient("http://or/api/v1", "mgmt-secret", name, http, clock=Clock())


def test_cache_reuses_within_ttl():
    calls = []
    clock = Clock()

    def handler(req):
        calls.append(req)
        return httpx.Response(200, json={"data": [{"model_name": "a"}]})

    c = gateway(handler, clock)
    c.model_info()
    clock.now = 29
    c.model_info()
    assert len(calls) == 1
    clock.now = 31
    c.model_info()
    assert len(calls) == 2
    assert calls[0].headers["authorization"] == f"Bearer {KEY}"


def test_write_clears_cache():
    calls = []

    def handler(req):
        calls.append((req.method, req.url.path))
        if req.url.path == "/model/info":
            return httpx.Response(200, json={"data": []})
        return httpx.Response(200, json={})

    c = gateway(handler)
    c.model_info()
    c.block("h1")
    c.model_info()
    assert calls == [("GET", "/model/info"), ("POST", "/key/block"), ("GET", "/model/info")]


def test_block_unblock_bodies():
    bodies = []

    def handler(req):
        bodies.append((req.url.path, json.loads(req.content)))
        return httpx.Response(200, json={})

    c = gateway(handler)
    c.block("h1")
    c.unblock("h1")
    assert bodies == [("/key/block", {"key": "h1"}), ("/key/unblock", {"key": "h1"})]


def test_unavailable_on_timeout_and_5xx():
    def h503(req):
        return httpx.Response(503, text="boom")

    with pytest.raises(Unavailable) as e:
        gateway(h503).model_info()
    assert e.value.source == "gateway"
    assert e.value.reason == "HTTP 503"

    def timeout(req):
        raise httpx.ReadTimeout("slow", request=req)

    with pytest.raises(Unavailable) as e:
        gateway(timeout).model_info()
    assert e.value.reason == "ReadTimeout"

    with pytest.raises(Unavailable) as e:
        gateway(timeout).block("h")
    assert e.value.source == "gateway"


def test_no_secret_in_errors(caplog):
    caplog.set_level(logging.DEBUG)

    def h500(req):
        return httpx.Response(500, text=f"echo {KEY}")

    def boom(req):
        raise httpx.ConnectError(f"cannot reach {req.headers['authorization']}", request=req)

    texts = []
    for h in (h500, boom):
        c = gateway(h)
        for call in (c.model_info, c.keys, lambda: c.key(KEY), lambda: c.block("h")):
            with pytest.raises(Unavailable) as e:
                call()
            texts += [str(e.value), e.value.reason, repr(e.value)]
    assert all(KEY not in t for t in texts)
    assert all(KEY not in r.getMessage() for r in caplog.records)
    assert all(KEY not in str(r.__dict__) for r in caplog.records)


def test_own_hash():
    c = gateway(lambda r: httpx.Response(500))
    assert c.own_hash() == hashlib.sha256(KEY.encode()).hexdigest()


def test_keys_paginates_and_null_blocked():
    def handler(req):
        page = int(req.url.params["page"])
        assert req.url.params["return_full_object"] == "true"
        key = {"token": f"h{page}", "key_alias": f"a{page}", "team_id": None, "blocked": None if page == 1 else True}
        return httpx.Response(200, json={"keys": [key], "total_pages": 2, "current_page": page})

    keys = gateway(handler).keys()
    assert [(k.token_hash, k.alias, k.blocked) for k in keys] == [("h1", "a1", False), ("h2", "a2", True)]


def test_keys_from_sample():
    sample = json.loads((SAMPLES / "gateway-key-list.json").read_text())
    sample["total_pages"] = 1
    keys = gateway(lambda r: httpx.Response(200, json=sample)).keys()
    assert len(keys) == len(sample["keys"])
    assert keys[0].token_hash == sample["keys"][0]["token"]


def test_team_key_budget_retention():
    def handler(req):
        p = req.url.path
        if p == "/team/info":
            assert req.url.params["team_id"] == "t1"
            return httpx.Response(200, json={"team_info": {"max_budget": 5.0}})
        if p == "/key/info":
            assert req.url.params["key"] == "h1"
            return httpx.Response(200, json={"key": "h1", "info": {"spend": 1.0}})
        if p == "/global/spend":
            return httpx.Response(200, json={"spend": 1.0, "max_budget": 32.0})
        if p == "/config/field/info":
            assert req.url.params["field_name"] == "maximum_spend_logs_retention_period"
            return httpx.Response(200, json={"field_value": "90d"})
        raise AssertionError(p)

    c = gateway(handler)
    assert c.team("t1")["team_info"]["max_budget"] == 5.0
    assert c.key("h1")["info"]["spend"] == 1.0
    assert c.global_budget() == 32.0
    assert c.retention() == "90d"


def test_budget_and_retention_none():
    c = gateway(lambda r: httpx.Response(200, json={"spend": 1.0, "max_budget": None, "field_value": None}))
    assert c.global_budget() is None
    assert c.retention() is None


def test_usage_rows():
    sample = json.loads((SAMPLES / "gateway-daily-activity.json").read_text())
    seen = []

    def handler(req):
        seen.append(dict(req.url.params))
        return httpx.Response(200, json=sample)

    rows = gateway(handler).usage(date(2026, 11, 6), date(2026, 11, 6))
    assert seen == [{"start_date": "2026-11-06", "end_date": "2026-11-06", "page": "1"}]
    by_name = {r.name: r for r in rows}
    assert set(by_name) == {"classify", "gpt-oss-120b@deepinfra"}
    r = by_name["classify"]
    assert (r.day, r.key_alias, r.calls, r.tokens_in, r.tokens_out) == (date(2026, 11, 6), "node-red", 2, 200, 100)
    assert r.spend_usd == pytest.approx(3.5e-05)


def test_usage_follows_pages():
    sample = json.loads((SAMPLES / "gateway-daily-activity.json").read_text())

    def handler(req):
        page = int(req.url.params["page"])
        body = json.loads(json.dumps(sample))
        body["metadata"].update(page=page, total_pages=2, has_more=page == 1)
        return httpx.Response(200, json=body)

    rows = gateway(handler).usage(date(2026, 11, 6), date(2026, 11, 6))
    assert len(rows) == 4


def test_zdr_sent_without_auth():
    seen = []

    def handler(req):
        seen.append(req)
        return httpx.Response(200, json={"data": [{"name": "x"}]})

    assert openrouter(handler).zdr_endpoints() == [{"name": "x"}]
    assert seen[0].url.path == "/api/v1/endpoints/zdr"
    assert "authorization" not in seen[0].headers


def keys_handler(listed, detail=None):
    def handler(req):
        assert req.headers["authorization"] == "Bearer mgmt-secret"
        if req.url.path == "/api/v1/keys":
            return httpx.Response(200, json={"data": listed})
        if req.url.path == "/api/v1/keys/abc":
            return httpx.Response(200, json={"data": detail or {"limit": 10}})
        raise AssertionError(req.url.path)

    return handler


def test_inference_key_found_by_name():
    listed = [{"name": "other", "hash": "zzz"}, {"name": "rapidselector-gateway", "hash": "abc"}]
    k = openrouter(keys_handler(listed)).inference_key()
    assert k == {"limit": 10, "hash": "abc"}


def test_inference_key_found_while_disabled():
    # OpenRouter's key list leaves disabled keys out unless include_disabled=true is sent, so
    # without it level 2 could not be read back or released (tests/tower.bats).
    listed = [{"name": "rapidselector-gateway", "hash": "abc", "disabled": True}]

    def handler(req):
        if req.url.path == "/api/v1/keys":
            shown = listed if req.url.params.get("include_disabled") == "true" else []
            return httpx.Response(200, json={"data": shown})
        return httpx.Response(200, json={"data": {"disabled": True}})

    assert openrouter(handler).inference_key() == {"disabled": True, "hash": "abc"}


def test_inference_key_missing():
    with pytest.raises(Unavailable) as e:
        openrouter(keys_handler([{"name": "other", "hash": "zzz"}])).inference_key()
    assert e.value.source == "openrouter"
    assert e.value.reason == "no key named rapidselector-gateway"


def test_credits_activity_set_disabled():
    seen = []

    def handler(req):
        seen.append((req.method, req.url.path, dict(req.url.params), req.content))
        if req.url.path.endswith("/credits"):
            return httpx.Response(200, json={"data": {"total_credits": 5, "total_usage": 1}})
        if req.url.path.endswith("/activity"):
            return httpx.Response(200, json={"data": [{"date": "2026-11-05"}]})
        return httpx.Response(200, json={"data": {}})

    c = openrouter(handler)
    assert c.credits() == {"total_credits": 5, "total_usage": 1}
    assert c.activity("abc") == [{"date": "2026-11-05"}]
    c.set_disabled("abc", True)
    assert seen[1][2] == {"api_key_hash": "abc"}
    assert seen[2][0] == "PATCH" and seen[2][1] == "/api/v1/keys/abc"
    assert json.loads(seen[2][3]) == {"disabled": True}


def test_openrouter_errors_have_no_secret(caplog):
    caplog.set_level(logging.DEBUG)
    c = openrouter(lambda r: httpx.Response(401, text="mgmt-secret"))
    with pytest.raises(Unavailable) as e:
        c.credits()
    assert (e.value.source, e.value.reason) == ("openrouter", "HTTP 401")
    assert "mgmt-secret" not in str(e.value)
    assert all("mgmt-secret" not in r.getMessage() for r in caplog.records)


def test_management_key_expiry_unknown():
    assert openrouter(lambda r: httpx.Response(500)).management_key_expiry() is None
