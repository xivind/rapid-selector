import dataclasses
from datetime import UTC, datetime, timedelta

from test_pages import Down, FakeGateway, FakeOpenRouter, config_dir, db, make_settings  # noqa: F401

from tower import setup_view, store


def build(config_dir, gw=None, orc=None, **changes):
    settings = dataclasses.replace(make_settings(config_dir), **changes)
    return setup_view.build(gw or FakeGateway(), orc or FakeOpenRouter(), settings)


def test_setup_open_webui_from_compose(db, config_dir):
    webui = dict(build(config_dir)["open_webui"])
    assert webui["TASK_MODEL_EXTERNAL"] == "llama-3.1-8b-instruct@deepinfra"
    assert webui["ENABLE_TAGS_GENERATION"] == "False"
    assert webui["WEBUI_SECRET_KEY"] == "secret, from .env"
    assert webui["OPENAI_API_KEY"] == "secret, from .env"


def test_setup_open_webui_missing_file(db, config_dir):
    (config_dir / "docker-compose.yml").unlink()
    assert build(config_dir)["open_webui"] is None


def test_setup_secrets_set_or_not_set(db, config_dir):
    secrets = dict(build(config_dir, smoke_key="")["secrets"])
    assert secrets == {
        "TOWER_PASSWORD": "set", "TOWER_SESSION_SECRET": "set", "OPENROUTER_MANAGEMENT_KEY": "set",
        "TOWER_GATEWAY_KEY": "set", "KEY_SMOKE_TEST": "not set",
    }


def test_setup_models(db, config_dir):
    store.log("price_check", "loop", False, "1 of 11 entries fail",
              {"results": {"classify": "flex tier", "summarise": "ok"}})
    models = {m["name"]: m for m in build(config_dir)["models"]}
    classify = models["classify"]
    assert (classify["kind"], classify["model"]) == ("role", "mistralai/mistral-small-3.2-24b-instruct")
    assert (classify["host"], classify["quantisation"]) == ("deepinfra", "fp8")
    assert classify["fallbacks"] == "off" and classify["zdr"] is True
    assert classify["price_in"] == 0.075 and classify["price_out"] == 0.2
    assert classify["max_tokens"] == 1024
    assert classify["price_check"] == "flex tier"
    assert models["summarise"]["price_check"] == "ok"
    cloudflare = models["llama-3.2-1b-instruct@cloudflare"]
    assert (cloudflare["host"], cloudflare["quantisation"]) == ("cloudflare", None)
    assert models["chat"]["price_check"] is None  # not in the latest run


def test_setup_teams_and_keys(db, config_dir):
    teams = build(config_dir)["teams_and_keys"]
    team = next(t for t in teams if t["id"] == "experiments")
    assert team["budget"] == 24.0 and team["window"] == "30d"
    assert "classify" in team["models"]
    assert team["keys"][0]["alias"] == "chat"
    loose = next(t for t in teams if t["id"] is None)
    assert loose["keys"][0]["alias"] == "smoke-test"  # from /key/info


def test_setup_gateway_settings_labelled(db, config_dir):
    up = {s["name"]: s for s in build(config_dir)["gateway_settings"]}
    assert (up["global budget"]["value"], up["global budget"]["source"]) == (32.0, "api")
    assert (up["budget window"]["value"], up["budget window"]["source"]) == ("30d", "config.yaml")
    assert up["spend log retention"]["source"] == "api"
    down = {s["name"]: s for s in build(config_dir, gw=Down("gateway"))["gateway_settings"]}
    assert (down["global budget"]["value"], down["global budget"]["source"]) == (32, "config.yaml")
    assert (down["spend log retention"]["value"], down["spend log retention"]["source"]) == ("90d", "config.yaml")


def test_setup_keys_at_openrouter(db, config_dir):
    expires = datetime.now(UTC) + timedelta(days=100, hours=1)
    view = build(config_dir, management_key_expires_at=expires)
    assert view["management_key"]["days_left"] == 100
    assert view["openrouter_key"]["limit"] == 35.0 and view["openrouter_key"]["disabled"] is False
    assert build(config_dir)["management_key"]["days_left"] is None


def test_setup_sources_down(db, config_dir):
    view = build(config_dir, gw=Down("gateway"), orc=Down("openrouter"))
    assert view["missing"] == ["gateway", "openrouter"]
    assert view["models"] is None and view["teams_and_keys"] is None and view["openrouter_key"] is None
    assert view["open_webui"] and view["secrets"]
