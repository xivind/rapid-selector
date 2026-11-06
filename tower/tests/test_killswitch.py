import hashlib
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from tower import app as app_module
from tower import store
from tower.app import create_app
from tower.clients import GatewayClient, GatewayKey, OpenRouterClient, Unavailable
from tower.killswitch import engage, enforce, read_state, release
from tower.settings import load_settings

OWN = "own-hash"
ENV = {
    "TOWER_PASSWORD": "pw-secret", "TOWER_SESSION_SECRET": "session-secret",
    "OPENROUTER_MANAGEMENT_KEY": "mgmt-secret", "TOWER_GATEWAY_KEY": "sk-gw-secret",
    "KEY_SMOKE_TEST": "sk-smoke-secret",
}


class FakeGateway:
    def __init__(self, names, blocked=()):
        self.state = {OWN: GatewayKey(OWN, "tower", None, False)}
        for n in names:
            self.add(n, n in blocked)
        self.fail = set()  # hashes whose block or unblock raises
        self.reads_left = None  # keys() raises once this reaches 0
        self.calls = []

    def add(self, name, blocked=False):
        self.state[name] = GatewayKey(name, name, None, blocked)

    def own_hash(self):
        return OWN

    def keys(self):
        if self.reads_left is not None:
            if self.reads_left == 0:
                raise Unavailable("gateway", "HTTP 503")
            self.reads_left -= 1
        return [GatewayKey(k.token_hash, k.alias, k.team_id, k.blocked) for k in self.state.values()]

    def _set(self, op, h, blocked):
        self.calls.append((op, h))
        if h in self.fail:
            raise Unavailable("gateway", "HTTP 500")
        self.state[h].blocked = blocked

    def block(self, h):
        self._set("block", h, True)

    def unblock(self, h):
        self._set("unblock", h, False)


class FakeOpenRouter:
    def __init__(self, disabled=False):
        self.disabled = disabled
        self.down = False
        self.calls = []

    def inference_key(self):
        if self.down:
            raise Unavailable("openrouter", "HTTP 503")
        return {"hash": "or-hash", "name": "rapidselector-gateway", "disabled": self.disabled}

    def set_disabled(self, h, disabled):
        self.calls.append((h, disabled))
        self.disabled = disabled


@pytest.fixture
def db(tmp_path):
    store.init_db(tmp_path / "tower.db")
    yield tmp_path
    store.db.close()


def recorded():
    return {b.token_hash for b in store.BlockedKey.select()}


def level2_flag():
    return store.Flag.get_or_none(store.Flag.name == "level2_by_tower") is not None


def keys(*specs):
    return [GatewayKey(OWN, "tower", None, False)] + [GatewayKey(h, h, None, b) for h, b in specs]


def browser(gw, orc):
    c = TestClient(create_app(load_settings(ENV), gateway=gw, openrouter=orc, start_loop=False),
                   follow_redirects=False)
    c.post("/login", data={"password": "pw-secret"})
    return c


# read_state (pure)

def test_read_state_all_clear():
    s = read_state(keys(("a", False), ("b", False)), {"disabled": False}, set(), False, OWN)
    assert s.level == 0
    assert not s.outside_tower
    assert s.blocked_by_tower == [] and s.blocked_outside == []
    assert s.openrouter_disabled is False
    assert s.problems == []


def test_read_state_unknown_when_gateway_down():
    s = read_state(Unavailable("gateway", "HTTP 503"), {"disabled": False}, set(), False, OWN)
    assert s.level is None
    assert any("gateway" in p for p in s.problems)
    s = read_state(keys(("a", True)), Unavailable("openrouter", "ConnectError"), {"a"}, False, OWN)
    assert s.level is None
    assert s.openrouter_disabled is None
    assert any("openrouter" in p for p in s.problems)


def test_level2_outside_tower():
    s = read_state(keys(("a", False)), {"disabled": True}, set(), False, OWN)
    assert s.level == 2 and s.outside_tower
    s = read_state(keys(("a", True)), {"disabled": True}, {"a"}, True, OWN)
    assert s.level == 2 and not s.outside_tower
    # The OpenRouter key alone decides level 2, even with the gateway down.
    s = read_state(Unavailable("gateway", "HTTP 503"), {"disabled": True}, set(), True, OWN)
    assert s.level == 2


def test_key_blocked_outside_tower():
    s = read_state(keys(("a", False), ("x", True)), {"disabled": False}, set(), False, OWN)
    assert s.level == 1 and s.outside_tower
    assert s.blocked_outside == ["x"] and s.blocked_by_tower == []
    assert not s.level1_complete
    s = read_state(keys(("a", True), ("x", True)), {"disabled": False}, {"a"}, False, OWN)
    assert s.blocked_by_tower == ["a"] and s.blocked_outside == ["x"]
    assert s.level1_complete


# engage

def test_engage_level1_blocks_all_but_tower(db):
    gw, orc = FakeGateway(["a", "b"]), FakeOpenRouter()
    s = engage(1, gw, orc, "owner")
    assert s.level == 1 and s.level1_complete and not s.outside_tower
    assert sorted(s.blocked_by_tower) == ["a", "b"]
    assert recorded() == {"a", "b"}
    assert ("block", OWN) not in gw.calls
    assert orc.calls == []
    entry = store.latest("kill_switch")
    assert entry.actor == "owner" and entry.ok is True


def test_engage_level1_partial_failure(db):
    gw, orc = FakeGateway(["a", "b", "c"]), FakeOpenRouter()
    gw.fail = {"c"}
    s = engage(1, gw, orc, "owner")
    assert recorded() == {"a", "b"}
    assert s.level == 1
    assert not s.level1_complete
    assert any("c" in p for p in s.problems)
    assert store.latest("kill_switch").ok is False
    gw.fail = set()
    gw.calls.clear()
    s = engage(1, gw, orc, "owner")
    assert gw.calls == [("block", "c")]
    assert recorded() == {"a", "b", "c"}
    assert s.level1_complete and s.problems == []


def test_engage_is_idempotent(db):
    gw, orc = FakeGateway(["a", "b"]), FakeOpenRouter()
    engage(1, gw, orc, "owner")
    gw.calls.clear()
    engage(1, gw, orc, "owner")
    assert gw.calls == []
    assert store.BlockedKey.select().count() == 2
    # A key tower recorded was unblocked by other means; engaging and enforcing both
    # block it again without recording it twice (insert-or-ignore, no IntegrityError).
    gw.state["a"].blocked = False
    engage(1, gw, orc, "owner")
    gw.state["a"].blocked = False
    assert enforce(gw) == ["a"]
    assert store.BlockedKey.select().count() == 2


def test_key_blocked_before_engage_is_not_released(db):
    gw, orc = FakeGateway(["a", "x"], blocked={"x"}), FakeOpenRouter()
    s = engage(1, gw, orc, "owner")
    assert recorded() == {"a"}
    assert s.blocked_outside == ["x"] and s.outside_tower
    s = release(1, gw, orc, "owner")
    assert ("unblock", "x") not in gw.calls
    assert gw.state["x"].blocked and not gw.state["a"].blocked
    assert s.level == 1 and s.blocked_outside == ["x"]


def test_engage_reads_fresh_keys(db):
    """A cached key list from before a key was blocked elsewhere must not make tower claim it."""
    up = Upstream({"a": False})
    gw, orc = up.clients()
    gw.keys()  # a page read caches "a" as not blocked
    up.keys["a"] = ("a", True)  # then it is blocked outside tower
    engage(1, gw, orc, "owner")
    assert "a" not in recorded()
    assert ("POST", "/key/block") not in up.calls


def test_engage_level2_also_engages_level1(db):
    gw, orc = FakeGateway(["a"]), FakeOpenRouter()
    s = engage(2, gw, orc, "owner")
    assert s.level == 2 and not s.outside_tower
    assert recorded() == {"a"}
    assert orc.calls == [("or-hash", True)]
    assert level2_flag()
    engage(2, gw, orc, "owner")
    assert len(orc.calls) == 1  # already disabled: no second call
    orc.disabled = False  # re-enabled by other means while tower's flag is set
    s = engage(2, gw, orc, "owner")
    assert orc.calls[-1] == ("or-hash", True) and s.level == 2


def test_engage_level2_with_openrouter_down_still_engages_level1(db):
    gw, orc = FakeGateway(["a"]), FakeOpenRouter()
    orc.down = True
    s = engage(2, gw, orc, "owner")
    assert recorded() == {"a"}
    assert not level2_flag()
    assert s.level is None and s.openrouter_disabled is None
    assert any("level 2 not engaged" in p for p in s.problems)


# release

def test_release_level1_refused_while_level2(db):
    gw, orc = FakeGateway(["a"]), FakeOpenRouter()
    engage(2, gw, orc, "owner")
    gw.calls.clear()
    s = release(1, gw, orc, "owner")
    assert gw.calls == [] and recorded() == {"a"}
    assert s.level == 2 and s.problems
    assert store.latest("kill_switch").ok is False
    # Also refused when the key was disabled outside tower, or cannot be read.
    store.Flag.delete().execute()
    assert release(1, gw, orc, "owner").problems and gw.calls == []
    orc.disabled, orc.down = False, True
    assert release(1, gw, orc, "owner").problems and gw.calls == []


def test_release_level2_leaves_level1(db):
    gw, orc = FakeGateway(["a"]), FakeOpenRouter()
    engage(2, gw, orc, "owner")
    s = release(2, gw, orc, "owner")
    assert orc.calls[-1] == ("or-hash", False)
    assert not level2_flag()
    assert s.level == 1 and gw.state["a"].blocked and recorded() == {"a"}
    s = release(1, gw, orc, "owner")
    assert s.level == 0 and recorded() == set()


def test_release_level2_never_enables_a_key_disabled_outside(db):
    gw, orc = FakeGateway(["a"]), FakeOpenRouter(disabled=True)
    engage(2, gw, orc, "owner")
    assert orc.calls == [] and not level2_flag()
    s = release(2, gw, orc, "owner")
    assert orc.calls == [] and orc.disabled
    assert s.level == 2 and s.outside_tower
    assert any("OpenRouter's dashboard" in p for p in s.problems)


def test_release_level1_drops_key_deleted_from_gateway(db):
    gw, orc = FakeGateway(["a", "b"]), FakeOpenRouter()
    engage(1, gw, orc, "owner")
    del gw.state["b"]
    s = release(1, gw, orc, "owner")
    assert ("unblock", "b") not in gw.calls
    assert recorded() == set() and s.level == 0


# enforce

def test_enforce_blocks_new_key(db):
    gw, orc = FakeGateway(["a"]), FakeOpenRouter()
    gw.add("new")
    assert enforce(gw) == [] and gw.calls == []  # nothing engaged by tower
    engage(1, gw, orc, "owner")
    gw.add("newer")
    assert enforce(gw) == ["newer"]
    assert "newer" in recorded()
    assert store.latest("kill_switch").actor == "loop"
    assert enforce(gw) == []


# routes

def test_release_requires_typed_word(db):
    gw, orc = FakeGateway(["a"]), FakeOpenRouter()
    c = browser(gw, orc)
    assert c.post("/kill/engage/1", data={"confirm": "yes"}).status_code == 200
    gw.calls.clear()
    r = c.post("/kill/release/1", data={"word": "Release"})
    assert r.status_code == 400
    assert gw.calls == [] and recorded() == {"a"}
    assert c.post("/kill/release/1", data={"word": "release"}).status_code == 200
    assert recorded() == set()


def test_engage_requires_confirmation(db):
    gw, orc = FakeGateway(["a"]), FakeOpenRouter()
    c = browser(gw, orc)
    first = c.get("/partials/killswitch?confirm=1")
    assert 'name="confirm" value="yes"' in first.text
    assert gw.calls == []
    assert c.post("/kill/engage/1", data={}).status_code == 400
    assert gw.calls == [] and recorded() == set()


def test_failed_readback_shows_unknown_not_engaged(db):
    gw, orc = FakeGateway(["a"]), FakeOpenRouter()
    gw.reads_left = 1  # engage's own read works; the read-back fails
    r = browser(gw, orc).post("/kill/engage/1", data={"confirm": "yes"})
    assert gw.state["a"].blocked
    assert "STATE UNKNOWN" in r.text
    assert 'class="ks-state warn"' in r.text
    assert "LEVEL 1" not in r.text and "engaged" not in r.text.lower()


def test_partial_states(db):
    gw, orc = FakeGateway(["a", "b"]), FakeOpenRouter()
    c = browser(gw, orc)
    assert "● ALL CLEAR" in c.get("/partials/killswitch").text
    gw.fail = {"b"}
    r = c.post("/kill/engage/1", data={"confirm": "yes"})
    assert "LEVEL 1 · PARTIAL" in r.text and "ALL CLEAR" not in r.text
    gw.fail = set()
    r = c.post("/kill/engage/2", data={"confirm": "yes"})
    assert "LEVEL 2" in r.text and 'hx-post="/kill/release/2"' in r.text
    assert 'hx-post="/kill/release/1"' not in r.text  # one level at a time
    store.Flag.delete().execute()  # as if disabled outside tower
    r = c.get("/partials/killswitch")
    assert "OpenRouter's dashboard" in r.text
    gw.state["a"].blocked, orc.disabled = True, False
    gw.add("x", blocked=True)
    assert "/ui" in c.get("/partials/killswitch").text


def test_killswitch_routes_need_login(db):
    c = TestClient(create_app(load_settings(ENV), gateway=FakeGateway([]), openrouter=FakeOpenRouter(),
                              start_loop=False), follow_redirects=False)
    assert c.get("/partials/killswitch").status_code == 303
    assert c.post("/kill/engage/1", data={"confirm": "yes"}).status_code == 401
    assert c.post("/kill/release/1", data={"word": "release"}).status_code == 401
    assert 'hx-get="/partials/killswitch"' not in c.get("/login").text
    c.post("/login", data={"password": "pw-secret"})
    assert 'hx-get="/partials/killswitch"' in c.get("/").text


def test_main_wires_store_and_clients(tmp_path, monkeypatch):
    for name, value in ENV.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setenv("TOWER_DATA_DIR", str(tmp_path))
    try:
        app = app_module.main()
        assert (tmp_path / "tower.db").exists()
        assert isinstance(app.state.gateway, GatewayClient)
        assert isinstance(app.state.openrouter, OpenRouterClient)
    finally:
        store.db.close()


# secrets

class Upstream:
    """The gateway's key routes and OpenRouter's management routes behind httpx.MockTransport."""

    def __init__(self, names):
        own = hashlib.sha256(ENV["TOWER_GATEWAY_KEY"].encode()).hexdigest()
        self.keys = {own: ("tower", False)} | {h: (h, b) for h, b in names.items()}
        self.disabled = False
        self.fail = set()
        self.calls = []

    def handle(self, req):
        self.calls.append((req.method, req.url.path))
        echo = {"error": f"auth {req.headers.get('authorization')}"}  # upstream echoing a key
        path = req.url.path
        if path == "/key/list":
            keys = [{"token": h, "key_alias": a, "blocked": b} for h, (a, b) in self.keys.items()]
            return httpx.Response(200, json={"keys": keys, "total_pages": 1})
        if path in ("/key/block", "/key/unblock"):
            h = json.loads(req.content)["key"]
            if h in self.fail:
                return httpx.Response(500, json=echo)
            self.keys[h] = (self.keys[h][0], path == "/key/block")
            return httpx.Response(200, json={})
        if path == "/api/v1/keys":
            return httpx.Response(200, json={"data": [{"name": "rapidselector-gateway", "hash": "or-hash"}]})
        if path == "/api/v1/keys/or-hash":
            if req.method == "PATCH":
                self.disabled = json.loads(req.content)["disabled"]
            return httpx.Response(200, json={"data": {"disabled": self.disabled, "label": "sk-or-v1-a…z"}})
        return httpx.Response(404, json=echo)

    def clients(self):
        http = httpx.Client(transport=httpx.MockTransport(self.handle))
        return (
            GatewayClient("http://gw", ENV["TOWER_GATEWAY_KEY"], http),
            OpenRouterClient("http://or/api/v1", ENV["OPENROUTER_MANAGEMENT_KEY"], "rapidselector-gateway", http),
        )


def test_log_detail_has_no_secrets(db):
    up = Upstream({"a": False, "b": False})
    up.fail = {"b"}
    gw, orc = up.clients()
    c = browser(gw, orc)
    pages = [c.post("/kill/engage/2", data={"confirm": "yes"}).text]
    up.fail = set()
    pages.append(c.post("/kill/engage/1", data={"confirm": "yes"}).text)
    pages.append(c.post("/kill/release/2", data={"word": "release"}).text)
    pages.append(c.post("/kill/release/1", data={"word": "release"}).text)
    assert not up.disabled and not any(b for _, b in up.keys.values())
    entries = store.entries()
    assert len(entries) == 4 and all(e.kind == "kill_switch" for e in entries)
    assert entries[-1].ok is False  # the failed block is in the log
    for e in entries:
        assert json.loads(e.detail)["action"] in ("engage", "release")
    text = "\n".join(pages + [e.summary + e.detail for e in entries])
    for secret in load_settings(ENV).secret_values():
        assert secret not in text
