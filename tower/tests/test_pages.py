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
    balance = text.split(">BALANCE<")[1].split("</div>")[0]
    assert "$12.60" in balance
    assert ">FORECAST<" in text and "estimate" in text[text.index(">FORECAST<"):][:200]
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


def test_cost_page_explains_reconciliation(db, config_dir):
    recon = browser(config_dir).get("/").text.split('id="recon-title"')[1].split("</section>")[0]
    assert "budgets count only the gateway's figures" in recon
    assert "OpenRouter's own limits still hold" in recon
    assert "Check prices" in recon


def test_setup_legend_names_every_light(db, config_dir):
    text = browser(config_dir).get("/setup").text
    legend = text.split('legend-lights">')[1].split("</p>")[0]
    for colour, word in (("go", "Ok"), ("caution", "Investigate"), ("stop", "Action required"), ("off", "No information")):
        assert f'<span class="dot {colour}" aria-hidden="true"></span>{word}' in legend


def test_setup_tab_says_why_only_when_yellow_or_red(db, config_dir):
    class TightGateway(FakeGateway):
        def global_budget(self):
            return 1.0  # below the team's budget: the gateway light turns red
    c = browser(config_dir, TightGateway())
    gateway = c.get("/setup?tab=gateway").text
    assert 'class="reason danger"' in gateway
    assert "add up to more than the global budget $1.00" in gateway.split('class="reason danger"')[1].split("</p>")[0]
    assert 'class="reason' not in c.get("/setup?tab=models").text  # not checked: no information, no line
    assert 'class="reason' not in c.get("/setup?tab=secrets").text  # all set: green, no line


def test_cost_page_bars_show_share_of_spend(db, config_dir):
    # summarise has the most calls, classify the most spend: the bars follow the money
    gw = FakeGateway([UsageRow(today(), "classify", "k", 1, 1, 1, 0.75),
                      UsageRow(today(), "summarise", "k", 9, 1, 1, 0.25)])
    roles = browser(config_dir, gw).get("/?period=day").text.split("ROLES")[1].split("MODELS")[0]
    classify, summarise = roles.split("summarise")
    assert '<rect class="fill" x="0" y="2" width="75.0"' in classify
    assert '<rect class="fill" x="0" y="2" width="25.0"' in summarise


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
        for path in ("/", "/usage", "/setup", "/setup?tab=teams", "/setup?tab=openrouter"):
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


SETUP_TABS = ("models", "teams", "openrouter", "gateway", "webui", "secrets")


def test_setup_page_renders(db, config_dir):
    c = browser(config_dir)
    for tab, texts in (("models", ("deepinfra", "fp8")), ("webui", ("TASK_MODEL_EXTERNAL", "secret, from .env",
                                                                    "./rapidselector.sh up")),
                       ("gateway", ("config.yaml",)), ("teams", ("experiments",)),
                       ("openrouter", ("sk-or-v1-abc...xyz",)), ("secrets", ("TOWER_GATEWAY_KEY",))):
        r = c.get(f"/setup?tab={tab}")
        assert r.status_code == 200
        for text in texts:
            assert text in r.text, (tab, text)


def test_setup_page_with_both_down(db, config_dir):
    c = browser(config_dir, gw=Down("gateway"), orc=Down("openrouter"))
    for tab in SETUP_TABS:
        r = c.get(f"/setup?tab={tab}")
        assert r.status_code == 200, tab
        assert "The gateway cannot be read" in r.text and "OpenRouter cannot be read" in r.text, tab
    assert "TASK_MODEL_EXTERNAL" in c.get("/setup?tab=webui").text  # from the file, not a source


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
    bodies = [c.get(p).text for p in ("/", "/?period=day", "/?period=week", "/usage",
                                       *(f"/setup?tab={t}" for t in SETUP_TABS), "/log", "/partials/killswitch", "/partials/checks",
                                       "/partials/killswitch?confirm=2", "/static/tower.css")]
    bodies.append(TestClient(c.app).get("/login").text)
    for down in (dict(gw=Down("gateway")), dict(orc=Down("openrouter"))):
        d = browser(config_dir, env=env, **down)
        bodies += [d.get(p).text for p in ("/", "/usage", *(f"/setup?tab={t}" for t in SETUP_TABS), "/log")]
    for body in bodies:
        for value in env.values():
            assert value not in body


# kill switch reachable on every page (final review I-2, owner decision)

def test_killswitch_placeholder_has_both_stop_buttons(db, config_dir):
    text = browser(config_dir).get("/").text
    ks = text.split('id="killswitch"')[1].split("<main")[0]
    assert 'hx-get="/partials/killswitch?confirm=1"' in ks
    assert 'hx-get="/partials/killswitch?confirm=2"' in ks


def test_killswitch_partial_within_deadline_when_sources_hang(db, config_dir, monkeypatch):
    monkeypatch.setattr(setup_view, "PAGE_DEADLINE", 1.0)
    release = threading.Event()
    try:
        c = browser(config_dir, gw=Hanging("gateway", release), orc=Hanging("openrouter", release))
        for method, path in (("get", "/partials/killswitch"), ("get", "/partials/killswitch?confirm=2"),
                             ("post", "/kill/engage/2")):
            start = time.monotonic()
            r = getattr(c, method)(path)
            assert r.status_code == 200
            assert time.monotonic() - start < 2.5, path
            assert "STATE UNKNOWN" in r.text
        assert 'hx-post="/kill/engage/2"' in c.get("/partials/killswitch?confirm=2").text
    finally:
        release.set()


def test_htmx_errors_are_shown_in_the_killswitch(db, config_dir):
    c = browser(config_dir)
    assert '<script src="/static/tower.js" defer></script>' in c.get("/").text
    js = c.get("/static/tower.js").text
    for text in ("htmx:responseError", "htmx:sendError", "killswitch",
                 "request failed", "reload, or use the README's manual stop"):
        assert text in js, text


def test_killswitch_all_clear_with_problems_is_not_green(db, config_dir):
    r = browser(config_dir).post("/kill/release/2", data={"word": "release"})  # nothing to release
    assert "ALL CLEAR" in r.text and "tower did not disable" in r.text
    assert 'class="ks-state warn"' in r.text and "ks-state clear" not in r.text


def test_killswitch_says_level1_leaves_the_master_key(db, config_dir):
    text = browser(config_dir).get("/partials/killswitch").text
    assert "Level 1 does not block LiteLLM's master key or the admin UI's own session key" in text


def test_setup_warns_about_a_malformed_expiry(db, config_dir):
    c = browser(config_dir, env={**ENV, "OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT": "next-year-x"})
    text = c.get("/setup?tab=openrouter").text
    assert "<code>OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT</code> is not a date (YYYY-MM-DD)" in text
    assert "next-year-x" not in text


def test_cost_page_says_when_per_day_lines_cannot_be_built(db, config_dir):
    class OtherShape(FakeOpenRouter):
        def activity(self, key_hash):
            return [{"day": "2026-11-01", "model_permaslug": "x", "usage": 0.1}]

    text = browser(config_dir, orc=OtherShape()).get("/").text
    assert "The per-day lines cannot be built (OpenRouter's activity shape was not as expected)" in text
    assert "per-day lines cannot be built" not in browser(config_dir).get("/").text


def test_cost_page_renders_when_the_summary_cannot_be_built(db, config_dir, monkeypatch):
    from tower import app as app_module

    def broken(**kw):
        raise RuntimeError("bug")

    monkeypatch.setattr(app_module, "cost_summary", broken)
    r = browser(config_dir).get("/")
    assert r.status_code == 200
    assert "The cost summary cannot be built" in r.text
    assert 'hx-get="/partials/killswitch?confirm=2"' in r.text


def test_css_has_no_label_below_085rem():
    import re
    css = (Path(__file__).resolve().parents[1] / "tower" / "static" / "tower.css").read_text()
    body = re.search(r"^body \{[^}]*\}", css, re.M).group(0)
    assert "1.1875rem" in body
    small = []
    for decl in re.findall(r"font(?:-size)?\s*:\s*([^;}]*)", css):
        if "clamp(" in decl:
            continue
        small += [v for v in re.findall(r"(?<![\d.])(\d*\.?\d+)rem", decl) if float(v) < 0.85]
    assert not small, small


def test_css_lights_differ_in_shape():
    """Colour alone must not tell the states apart: go and off round, caution a triangle, stop a square."""
    import re
    css = (Path(__file__).resolve().parents[1] / "tower" / "static" / "tower.css").read_text()
    rule = lambda sel: re.search(r"^\.dot" + sel + r" \{([^}]*)\}", css, re.M).group(1)
    assert "border-radius: 50%" in rule("")
    assert "clip-path: polygon(50% 0, 100% 100%, 0 100%)" in rule(r"\.caution")
    assert "border-radius: 0" in rule(r"\.stop")
    for sel in (r"\.go", r"\.off", r"\.stop"):
        assert "clip-path" not in rule(sel)


def _compare_rows():
    t = today()
    return [UsageRow(t, "classify", "node-red", 10, 1, 1, 1.85),
            UsageRow(t - timedelta(days=1), "classify", "node-red", 4, 1, 1, 0.25),
            UsageRow(t - timedelta(days=7), "classify", "node-red", 20, 1, 1, 2.40)]


def _cards(text):
    return text.split('class="cards"')[1].split("</section>")[0] if 'class="cards"' in text else ""


def test_cost_page_shows_yesterday_and_week_change(db, config_dir):
    text = browser(config_dir, FakeGateway(_compare_rows())).get("/").text
    cards = _cards(text)
    assert "yesterday $0.25" in cards
    assert 'class="down"' in cards  # this week 2.10 (1.85 on a Monday) against 2.40


class LowBalance(FakeOpenRouter):
    def credits(self):
        return {"total_credits": 20.0, "total_usage": 18.6}


def test_cost_page_balance_line_colour(db, config_dir):
    assert "above the $2 threshold" in _cards(browser(config_dir).get("/").text)
    cards = _cards(browser(config_dir, orc=LowBalance()).get("/").text)
    assert "$1.40" in cards
    assert 'class="threshold danger">below the $2 threshold' in cards


def test_cost_page_without_gateway_comparison(db, config_dir):
    r = browser(config_dir, gw=Down("gateway")).get("/")
    assert r.status_code == 200
    cards = _cards(r.text)
    assert "$0.31" in cards  # today's figure is OpenRouter's
    assert "yesterday" not in cards
    assert 'class="down"' not in cards and 'class="up"' not in cards and 'class="new"' not in cards


def test_usage_page_shows_yday_and_changes(db, config_dir):
    text = browser(config_dir, FakeGateway(_compare_rows())).get("/usage").text
    classify = text.split("classify")[1].split("</tbody>")[0]
    assert "yday $0.25" in classify
    assert 'class="new"' in classify  # nothing in the same days of last month
    assert 'class="down"' in classify or 'class="up"' in classify  # the week against last week


def test_panel_all_clear(db, config_dir):
    text = browser(config_dir).get("/partials/killswitch").text
    assert 'class="killswitch status-panel"' in text and "engaged" not in text
    assert 'class="dot go big"' in text and "ALL CLEAR" in text
    for word in ("gateway keys", "OpenRouter key", "price check", "reconciliation", "KILL SWITCH"):
        assert word in text, word
    assert 'hx-get="/partials/killswitch?confirm=1"' in text and 'hx-get="/partials/killswitch?confirm=2"' in text
    fixed = text.split("<details")[1].split("</details>")[0]
    assert "What the levels do" in fixed and "master key" in fixed


def test_setup_tabs_default_models(db, config_dir):
    text = browser(config_dir).get("/setup").text
    assert 'class="data models"' in text and "/team/info" not in text
    for tab in SETUP_TABS:
        assert f'href="/setup?tab={tab}"' in text, tab
    import re
    current = re.findall(r'<a href="/setup\?tab=(\w+)"[^>]*aria-current="page"', text)
    assert current == ["models"]
    nav = text.split('class="subtabs"')[1].split("</nav>")[0]
    assert nav.count('class="dot ') == 6  # every tab


def test_setup_tab_openrouter_has_both_keys(db, config_dir):
    text = browser(config_dir).get("/setup?tab=openrouter").text
    assert "sk-or-v1-abc...xyz" in text and "Management key" in text
    assert 'class="data models"' not in text


def test_setup_unknown_tab_422(db, config_dir):
    assert browser(config_dir).get("/setup?tab=everything").status_code == 422


def test_setup_models_badges(db, config_dir):
    text = browser(config_dir).get("/setup").text
    assert 'class="badge go">ZDR</span>' in text and 'class="badge plain">no fallback</span>' in text


def test_setup_tab_light_word_on_hover(db, config_dir):
    text = browser(config_dir).get("/setup").text
    assert 'href="/setup?tab=secrets" title="Secrets: all set"' in text


def test_usage_page_marks_standouts(db, config_dir):
    t = today()
    rows = [UsageRow(t, "classify", "node-red", 41, 4120, 824, 0.12),
            UsageRow(t, "chat", "chat", 3, 300, 600, 0.05),
            UsageRow(t, "summarise", "node-red", 4, 9800, 700, 0.02),
            UsageRow(t, "code", "node-red", 2, 200, 5200, 0.01)]
    text = browser(config_dir, FakeGateway(rows)).get("/usage").text
    roles = text.split(">Roles<")[1].split("</section>")[0]
    assert '<span class="hi">$0.12</span>' in roles and '<span class="hi">41</span>' in roles
    assert '<span class="hi">9,800</span>' in roles and '<span class="hi">5,200</span>' in roles
    assert '<span class="hi">$0.05</span>' not in roles
