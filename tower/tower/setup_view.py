"""The Setup page's data, and the deadline-bound fetch every page uses.

Each client call runs in its own thread. A call that raises, or has not answered by the page's
deadline, counts as its source missing, so a slow or broken gateway or OpenRouter never holds a
page for long. Values from the mounted files are labelled with the file they came from.
"""

import json
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime

import yaml

from tower import store
from tower.checks import _prices
from tower.clients import Unavailable
from tower.killswitch import _try
from tower.settings import SECRET_NAMES

PAGE_DEADLINE = 5.0  # seconds for all of a page's calls together
_pool = ThreadPoolExecutor(max_workers=16, thread_name_prefix="tower-page")


def deadline() -> float:
    return time.monotonic() + PAGE_DEADLINE


def gather(calls: dict, end: float) -> dict:
    """calls: name -> (source, fn). Returns name -> the value, or Unavailable naming the source."""
    futures = {name: (source, _pool.submit(_try, source, fn)) for name, (source, fn) in calls.items()}
    out = {}
    for name, (source, future) in futures.items():
        try:
            out[name] = future.result(timeout=max(0.0, end - time.monotonic()))
        except TimeoutError:
            out[name] = Unavailable(source, "no answer in time")
    return out


def missing(*values) -> list[str]:
    return sorted({v.source for v in values if isinstance(v, Unavailable)})


def _yaml(path):
    try:
        return yaml.safe_load(path.read_text()) or {}
    except (OSError, yaml.YAMLError):
        return None


def _dig(data, *path):
    for key in path:
        if not isinstance(data, dict) or key not in data:
            return None
        data = data[key]
    return data


def gateway_config(settings) -> dict | None:
    return _yaml(settings.config_dir / "config.yaml")


def gateway_window(settings) -> str | None:
    value = _dig(gateway_config(settings), "litellm_settings", "budget_duration")
    return None if value is None else str(value)


def latest_price_check():
    """(time, {name: "ok" or the reason}) of the latest price check, or (None, {})."""
    try:
        entry = store.latest("price_check")
        return (entry.at, json.loads(entry.detail).get("results", {})) if entry else (None, {})
    except Exception:  # an unreadable store must not break the page
        return None, {}


def _per_million(price):
    try:
        return round(float(price) * 1_000_000, 6)
    except (TypeError, ValueError):
        return None


def _models(models, results) -> list[dict]:
    out = []
    for e in models:
        params, info = e.get("litellm_params") or {}, e.get("model_info") or {}
        provider = _dig(params, "extra_body", "provider") or {}
        host, _, quant = str((provider.get("order") or ["?"])[0]).partition("/")
        price_in, price_out = _prices(e)
        name = e.get("model_name", "?")
        out.append({
            "name": name,
            "kind": info.get("rapidselector_kind", "experiment"),
            "model": str(params.get("model", "?")).removeprefix("openrouter/"),
            "host": host,
            "quantisation": quant or None,
            "fallbacks": "on" if provider.get("allow_fallbacks", True) else "off",  # OpenRouter's default is on
            "zdr": provider.get("zdr") is True,
            "price_in": _per_million(price_in),
            "price_out": _per_million(price_out),
            "max_tokens": params.get("max_tokens"),
            "price_check": results.get(name),
        })
    return out


def _limits(d) -> dict:
    return {"budget": d.get("max_budget"), "spend": d.get("spend"), "reset": d.get("budget_reset_at"),
            "window": d.get("budget_duration"), "models": d.get("models") or [],
            "tpm": d.get("tpm_limit"), "rpm": d.get("rpm_limit"),
            "parallel": d.get("max_parallel_requests"), "blocked": bool(d.get("blocked"))}


def _teams(keys, teams, loose) -> list[dict]:
    out = []
    for team_id, body in teams.items():
        info = body.get("team_info") or {}
        out.append({"id": team_id, "alias": info.get("team_alias") or team_id, **_limits(info),
                    "keys": [{"alias": k.get("key_alias"), **_limits(k)} for k in body.get("keys") or []]})
    rows = []
    for k in keys:
        if k.team_id is None:
            info = loose.get(k.token_hash)
            if isinstance(info, dict):
                detail = info.get("info") or {}
                rows.append({"alias": detail.get("key_alias") or k.alias, **_limits(detail)})
            else:
                rows.append({"alias": k.alias, **_limits({"blocked": k.blocked}), "unread": True})
    if rows:
        out.append({"id": None, "alias": "no team", **_limits({}), "keys": rows})
    return out


def _openrouter_key(key) -> dict:
    fields = ("label", "limit", "limit_remaining", "limit_reset", "usage_monthly", "usage", "disabled")
    return {f: key.get(f) for f in fields}


def _gateway_settings(cfg, budget, retention) -> list[dict]:
    def setting(name, api_value, *path):
        if not isinstance(api_value, Unavailable) and api_value is not None:
            return {"name": name, "value": api_value, "source": "api"}
        value = _dig(cfg, *path)
        return {"name": name, "value": value, "source": "config.yaml" if value is not None else None}

    return [
        setting("global budget", budget, "litellm_settings", "max_budget"),
        setting("budget window", None, "litellm_settings", "budget_duration"),
        setting("spend log retention", retention, "general_settings", "maximum_spend_logs_retention_period"),
    ]


def _open_webui(settings) -> list[tuple[str, str]] | None:
    env = _dig(_yaml(settings.config_dir / "docker-compose.yml"), "services", "chat", "environment")
    if isinstance(env, list):
        env = dict(item.partition("=")[::2] for item in env)
    if not isinstance(env, dict):
        return None
    return [(k, "secret, from .env" if "${" in str(v) else str(v)) for k, v in env.items()]


def build(gw, orc, settings) -> dict:
    end = deadline()
    got = gather({
        "models": ("gateway", lambda: gw.model_info()),
        "keys": ("gateway", lambda: gw.keys()),
        "budget": ("gateway", lambda: gw.global_budget()),
        "retention": ("gateway", lambda: gw.retention()),
        "or_key": ("openrouter", lambda: orc.inference_key()),
        "expiry": ("openrouter", lambda: orc.management_key_expiry()),
    }, end)
    keys = got["keys"]
    teams, loose = {}, {}
    if not isinstance(keys, Unavailable):
        team_ids = sorted({k.team_id for k in keys if k.team_id})
        loose_keys = [k.token_hash for k in keys if k.team_id is None]
        more = gather({**{("team", t): ("gateway", lambda t=t: gw.team(t)) for t in team_ids},
                       **{("key", h): ("gateway", lambda h=h: gw.key(h)) for h in loose_keys}}, end)
        teams = {t: more[("team", t)] for t in team_ids}
        loose = {h: more[("key", h)] for h in loose_keys}
        if any(isinstance(v, Unavailable) for v in teams.values()):
            keys = next(v for v in teams.values() if isinstance(v, Unavailable))

    expires = got["expiry"] if isinstance(got["expiry"], datetime) else settings.management_key_expires_at
    _, results = latest_price_check()

    def section(source_value, make):
        if isinstance(source_value, Unavailable):
            return None
        try:
            return make()
        except Exception:  # a malformed answer shows as missing, not as a broken page
            return None

    view = {
        "models": section(got["models"], lambda: _models(got["models"], results)),
        "teams_and_keys": section(keys, lambda: _teams(keys, teams, loose)),
        "openrouter_key": section(got["or_key"], lambda: _openrouter_key(got["or_key"])),
        "management_key": {
            "expires_at": expires,
            "days_left": (expires - datetime.now(UTC)).days if expires else None,
            "setting_invalid": settings.management_key_expires_at_invalid,
        },
        "gateway_settings": _gateway_settings(gateway_config(settings), got["budget"], got["retention"]),
        "open_webui": _open_webui(settings),
        "secrets": [(name, "set" if value else "not set")
                    for name, value in zip(SECRET_NAMES, settings.secret_values())],
    }
    view["missing"] = sorted({source for source, name in (("gateway", "models"), ("gateway", "teams_and_keys"),
                                                          ("openrouter", "openrouter_key")) if view[name] is None})
    return view
