import json
import threading
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from tower import setup_view, store
from tower.app import create_app
from tower.clients import GatewayKey, UsageRow, Unavailable
from tower.settings import load_settings

SAMPLES = Path(__file__).parent / "samples"
REPO = Path(__file__).resolve().parents[2]
MODELS = json.loads((SAMPLES / "gateway-model-info.json").read_text())["data"]
TEAM = json.loads((SAMPLES / "gateway-team-info.json").read_text())
KEY_INFO = json.loads((SAMPLES / "gateway-key-info.json").read_text())
ENV = {
    "TOWER_PASSWORD": "pw-secret", "TOWER_SESSION_SECRET": "session-secret",
    "OPENROUTER_MANAGEMENT_KEY": "mgmt-secret", "TOWER_GATEWAY_KEY": "sk-gw-secret",
    "KEY_SMOKE_TEST": "sk-smoke-secret",
}


def today():
    return datetime.now(UTC).date()


class FakeGateway:
    def __init__(self, rows=None):
        self.rows = rows if rows is not None else [
            UsageRow(today(), "classify", "node-red", 412, 41200, 8240, 3.10),
            UsageRow(today(), "chat", "chat", 131, 13100, 26200, 2.30),
            UsageRow(today(), "gpt-oss-120b@deepinfra", "bench", 20, 2000, 4000, 2.00),
        ]

    def own_hash(self):
        return "hash-tower"

    def model_info(self):
        return MODELS

    def usage(self, start, end):
        return [r for r in self.rows if start <= r.day <= end]

    def global_budget(self):
        return 32.0

    def retention(self):
        return "90d"

    def keys(self):
        return [GatewayKey("hash-tower", "tower", None, False),
                GatewayKey("hash-chat", "chat", "experiments", False)]

    def team(self, team_id):
        return TEAM

    def key(self, alias_or_hash):
        return KEY_INFO


class FakeOpenRouter:
    def inference_key(self):
        return {"hash": "or-hash", "name": "rapidselector-gateway", "label": "sk-or-v1-abc...xyz",
                "disabled": False, "limit": 35.0, "limit_remaining": 27.6, "limit_reset": "monthly",
                "usage": 40.0, "usage_daily": 0.31, "usage_weekly": 2.10, "usage_monthly": 7.40}

    def credits(self):
        return {"total_credits": 20.0, "total_usage": 7.40}

    def activity(self, key_hash):
        return []

    def management_key_expiry(self):
        return None


class Down:
    """Every call fails as if the source cannot be reached."""

    def __init__(self, source):
        self.source = source

    def own_hash(self):
        return "hash-tower"

    def __getattr__(self, name):
        def fail(*a, **kw):
            raise Unavailable(self.source, "ConnectError")
        return fail


class Hanging(Down):
    """Every call blocks until released, like a source that accepts the connection and never answers."""

    def __init__(self, source, release):
        super().__init__(source)
        self.release = release

    def __getattr__(self, name):
        def hang(*a, **kw):
            self.release.wait(10)
            raise Unavailable(self.source, "ReadTimeout")
        return hang


@pytest.fixture
def config_dir(tmp_path):
    d = tmp_path / "config"
    d.mkdir()
    (d / "config.yaml").symlink_to(REPO / "gateway" / "config.yaml")
    (d / "docker-compose.yml").symlink_to(REPO / "docker-compose.yml")
    return d


@pytest.fixture
def db(tmp_path):
    store.init_db(tmp_path / "tower.db")
    yield tmp_path
    store.db.close()


def make_settings(config_dir, env=ENV):
    return load_settings({**env, "TOWER_CONFIG_DIR": str(config_dir)})


def browser(config_dir, gw=None, orc=None, env=ENV):
    app = create_app(make_settings(config_dir, env), gateway=gw or FakeGateway(),
                     openrouter=orc or FakeOpenRouter(), start_loop=False)
    c = TestClient(app, follow_redirects=False)
    c.post("/login", data={"password": env["TOWER_PASSWORD"]})
    return c


def test_cost_page_shows_figures(db, config_dir):
    r = browser(config_dir).get("/")
    assert r.status_code == 200
    text = r.text
    assert "$7.40" in text
    assert "key limit $35" in text
    assert "balance $12.60" in text
    assert "forecast" in text and "estimate" in text[text.index("forecast"):][:200]
    assert "classify" in text and "mistralai/mistral-small-3.2-24b-instruct@deepinfra" in text
    assert "in step" in text  # monthly key reset against the gateway's 30d window
    assert '<svg class="bar' in text
    assert 'id="checks"' in text  # the checks partial is on the Cost page
    assert 'id="killswitch"' in text
    assert "warn" not in text.split("<main")[1].split('id="checks"')[0]


def test_cost_page_period_switches_top_lists(db, config_dir):
    yesterday = today() - timedelta(days=1)
    gw = FakeGateway([UsageRow(yesterday, "summarise", "k", 5, 1, 1, 0.5),
                      UsageRow(today(), "classify", "k", 7, 1, 1, 0.1)])
    c = browser(config_dir, gw)
    day = c.get("/?period=day").text
    roles_day = day.split("ROLES")[1].split("MODELS")[0]
    assert "classify" in roles_day and "summarise" not in roles_day
    month = c.get("/").text
    if yesterday.month == today().month:
        assert "summarise" in month.split("ROLES")[1].split("MODELS")[0]
    assert c.get("/?period=year").status_code == 422


def test_cost_page_renders_with_gateway_down(db, config_dir):
    c = browser(config_dir, gw=Down("gateway"))
    r = c.get("/")
    assert r.status_code == 200
    assert "The gateway cannot be read" in r.text
    assert 'class="warn' in r.text
    assert "$7.40" in r.text  # OpenRouter's figures still show
    assert 'id="killswitch"' in r.text and 'hx-get="/partials/killswitch"' in r.text
    ks = c.get("/partials/killswitch")
    assert ks.status_code == 200 and "STOP" in ks.text  # level 2 is still reachable


def test_cost_page_renders_with_openrouter_down(db, config_dir):
    r = browser(config_dir, orc=Down("openrouter")).get("/")
    assert r.status_code == 200
    assert "OpenRouter cannot be read" in r.text
    assert 'class="warn' in r.text
    assert "classify" in r.text  # the gateway's figures still show


def test_cost_page_survives_malformed_answers(db, config_dir):
    class Odd(FakeOpenRouter):
        def credits(self):
            return {"total_credits": "lots"}

        def inference_key(self):
            return {"hash": "or-hash", "usage_monthly": "seven"}

        def activity(self, key_hash):
            return [{"no": "date"}]

    r = browser(config_dir, orc=Odd()).get("/")
    assert r.status_code == 200
    assert "OpenRouter cannot be read" in r.text


def test_pages_render_within_deadline_when_sources_hang(db, config_dir, monkeypatch):
    monkeypatch.setattr(setup_view, "PAGE_DEADLINE", 1.0)
    release = threading.Event()
    try:
        c = browser(config_dir, gw=Hanging("gateway", release), orc=Hanging("openrouter", release))
        for path in ("/", "/usage", "/setup"):
            start = time.monotonic()
            r = c.get(path)
            assert r.status_code == 200
            assert time.monotonic() - start < 2.5, path
            assert 'class="warn' in r.text
    finally:
        release.set()


def test_page_deadline_is_under_six_seconds():
    assert setup_view.PAGE_DEADLINE <= 5.5


def test_usage_lists_roles_and_experiments_apart(db, config_dir):
    text = browser(config_dir).get("/usage").text
    roles = text.index("Roles")
    experiments = text.index("Experiment names")
    keys = text.index("Keys")
    assert roles < experiments < keys
    assert roles < text.index("classify") < experiments
    assert experiments < text.index("gpt-oss-120b@deepinfra", experiments) < keys
    assert "gpt-oss-120b@deepinfra" not in text[roles:experiments]
    assert "node-red" in text[keys:]


def test_usage_renders_with_gateway_down(db, config_dir):
    r = browser(config_dir, gw=Down("gateway")).get("/usage")
    assert r.status_code == 200 and "The gateway cannot be read" in r.text


def test_setup_page_renders(db, config_dir):
    r = browser(config_dir).get("/setup")
    assert r.status_code == 200
    for text in ("deepinfra", "fp8", "TASK_MODEL_EXTERNAL", "secret, from .env",
                 "config.yaml", "experiments", "sk-or-v1-abc...xyz", "TOWER_GATEWAY_KEY",
                 "./rapidselector.sh up"):
        assert text in r.text, text


def test_setup_page_with_both_down(db, config_dir):
    r = browser(config_dir, gw=Down("gateway"), orc=Down("openrouter")).get("/setup")
    assert r.status_code == 200
    assert "The gateway cannot be read" in r.text and "OpenRouter cannot be read" in r.text
    assert "TASK_MODEL_EXTERNAL" in r.text  # from the file, not a source


def test_log_newest_first(db, config_dir):
    t = datetime(2026, 11, 5, 6, 30, tzinfo=UTC)
    store.log("price_check", "loop", True, "all prices match", {}, at=t)
    store.log("kill_switch", "owner", True, "engage level 1: blocked 3 key(s)", {}, at=t + timedelta(hours=2))
    store.log("smoke_test", "owner", False, "FAILED: 4 call(s), $0.000100", {}, at=t + timedelta(hours=1))
    text = browser(config_dir).get("/log").text
    a = text.index("engage level 1")
    b = text.index("FAILED: 4 call(s)")
    c = text.index("all prices match")
    assert a < b < c
    assert "2026-11-05 08:30" in text
    assert 'class="danger' in text[b - 400:b]  # the failed run stands out


def test_killswitch_refusal_is_shown(db, config_dir):
    # htmx 2 does not swap 4xx answers, so "nothing changed" must come back as 200.
    c = browser(config_dir)
    r = c.post("/kill/engage/1", data={})
    assert r.status_code == 200 and "Nothing changed" in r.text


def test_bar_macro():
    from jinja2 import Environment, FileSystemLoader

    env = Environment(loader=FileSystemLoader(Path(setup_view.__file__).parent / "templates"))
    bar = env.from_string('{% from "macros/bars.html" import bar %}{{ bar(v, m, marker) }}')
    half = bar.render(v=5, m=10, marker=8)
    assert 'width="50.0"' in half and 'x1="80.0"' in half and "over" not in half
    over = bar.render(v=12, m=10, marker=None)
    assert 'width="100.0"' in over and "over" in over and "<line" not in over
    empty = bar.render(v=None, m=None, marker=None)
    assert "nan" not in empty.lower() and 'width="0.0"' in empty


def test_no_secret_in_any_page(db, config_dir):
    env = {name: f"MARKER-{i}-{name}" for i, name in enumerate(ENV)}
    store.log("kill_switch", "owner", True, "engage level 1: blocked 1 key(s)", {})
    c = browser(config_dir, env=env)
    bodies = [c.get(p).text for p in ("/", "/?period=day", "/?period=week", "/usage", "/setup",
                                       "/log", "/partials/killswitch", "/partials/checks",
                                       "/partials/killswitch?confirm=2", "/static/tower.css")]
    bodies.append(TestClient(c.app).get("/login").text)
    for down in (dict(gw=Down("gateway")), dict(orc=Down("openrouter"))):
        d = browser(config_dir, env=env, **down)
        bodies += [d.get(p).text for p in ("/", "/usage", "/setup", "/log")]
    for body in bodies:
        for value in env.values():
            assert value not in body
