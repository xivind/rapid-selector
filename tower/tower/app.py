import hmac
import os
import time
from collections.abc import Callable
from contextlib import asynccontextmanager
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Literal

import httpx
from fastapi import APIRouter, Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from starlette.middleware.sessions import SessionMiddleware

from tower import checks, killswitch, metrics, setup_view, store
from tower.clients import GatewayClient, OpenRouterClient, Unavailable
from tower.settings import Settings, load_settings
from tower.summary import cost_summary, period_bounds, reconcile_days, usage_tables

HERE = Path(__file__).parent
SESSION_MAX_AGE = 30 * 24 * 3600
THROTTLE_TRIES = 5
THROTTLE_WINDOW = 60.0


REGISTRARS: list[Callable[[APIRouter, FastAPI], None]] = [killswitch.register, checks.register]
USAGE_DAYS = 30  # covers this month, this week (which can start last month) and OpenRouter's activity
USAGE_DAYS_COMPARED = 62  # Usage also shows the same days of last month
LOG_KINDS = {"kill_switch": "kill switch", "price_check": "price check", "smoke_test": "smoke test",
             "balance": "balance"}


def usd(value, short=False) -> str:
    """$7.40; $35 with short=True for whole dollars (limits, budgets); six places below a cent,
    so a tiny spend is not shown as $0.00."""
    try:
        v = float(value)
    except (TypeError, ValueError):
        return "\u2014"
    if short and v == int(v):
        return f"${v:,.0f}"
    if v and abs(v) < 0.01:
        return f"${v:.6f}"
    return f"${v:,.2f}"


def when(value) -> str:
    """1 Dec 00:00 UTC, from a datetime or an ISO 8601 string (as LiteLLM gives reset times)."""
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value)
        except ValueError:
            return value
    if not isinstance(value, datetime):
        return "\u2014"
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(UTC).strftime("%-d %b %H:%M UTC")


def stamp(value) -> str:
    return value.astimezone(UTC).strftime("%Y-%m-%d %H:%M") if isinstance(value, datetime) else "\u2014"


def _store(read, default):
    try:
        return read()
    except Exception:  # an unreadable store must not break a page
        return default


def _summary(got, activity, window, now, period):
    """The cost summary and the per-day reconciliation. A malformed answer counts as its source
    missing: if the summary cannot be built, it is built again without OpenRouter, then without
    the gateway, then without both."""
    sources = {"inference_key": "openrouter", "credits": "openrouter", "usage": "gateway",
               "models": "gateway", "global_budget": "gateway"}
    latest = {kind: _store(lambda kind=kind: store.latest(kind), None) for kind in ("price_check", "smoke_test")}
    summary = None
    for drop in ((), ("openrouter",), ("gateway",), ("openrouter", "gateway")):
        values = {name: Unavailable(src, "unreadable answer") if src in drop else got[name]
                  for name, src in sources.items()}
        try:
            summary = cost_summary(**values, global_window=window, price_check=latest["price_check"],
                                   smoke_test=latest["smoke_test"], now=now, period=period)
            break
        except Exception:
            continue
    if summary is None:  # not even without both sources: shown as such, never an unbound name
        return None, None
    days = None
    if not setup_view.missing(got["usage"], got["models"], got["inference_key"], activity):
        try:
            days = reconcile_days(got["usage"], activity, got["models"], summary.spend_day_usd or 0.0, now.date())
        except Exception:
            pass  # shown as missing
    return summary, days


def require_login(request: Request) -> None:
    """Dependency for every route except /health, /metrics, /login and /static."""
    if request.session.get("logged_in"):
        return
    if request.method == "GET":
        raise HTTPException(status_code=303, headers={"Location": "/login"})
    raise HTTPException(status_code=401, detail="login required")


def create_app(settings: Settings, *, gateway=None, openrouter=None, start_loop: bool = True) -> FastAPI:
    @asynccontextmanager
    async def lifespan(_app):
        stop = None
        if start_loop:
            from tower import loop  # imported here: loop imports this module

            stop = loop.start_loop(app)
        yield
        if stop:
            stop()

    app = FastAPI(title="rapidselector tower", docs_url=None, redoc_url=None, openapi_url=None,
                  lifespan=lifespan)
    app.state.settings = settings
    http = httpx.Client()  # shared by the default clients; tests pass their own
    if gateway is None:
        gateway = GatewayClient(settings.gateway_url, settings.gateway_key, http)
    if openrouter is None:
        openrouter = OpenRouterClient(
            settings.openrouter_url, settings.management_key, settings.inference_key_name, http
        )
    app.state.gateway = gateway
    app.state.openrouter = openrouter
    app.state.templates = Jinja2Templates(directory=HERE / "templates")
    app.state.templates.env.filters.update(usd=usd, when=when, stamp=stamp)
    app.add_middleware(
        SessionMiddleware,
        secret_key=settings.session_secret,
        session_cookie="tower_session",
        max_age=SESSION_MAX_AGE,
        same_site="strict",
        https_only=False,  # plain HTTP on the LAN
    )
    app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")
    failures: dict[str, list[float]] = {}  # client IP -> times of counted wrong tries

    # Every page module exposes register(router, app) and is listed in REGISTRARS.
    # The router below requires login; it is filled before it is included, because
    # include_router copies the routes that exist at that moment.
    protected = APIRouter(dependencies=[Depends(require_login)])

    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.get("/metrics")
    def metrics_page():
        return Response(generate_latest(metrics.REGISTRY), media_type=CONTENT_TYPE_LATEST)

    def login_page(request: Request, message: str | None = None, status_code: int = 200):
        return app.state.templates.TemplateResponse(
            request, "login.html", {"message": message}, status_code=status_code
        )

    @app.get("/login", response_class=HTMLResponse)
    def login_form(request: Request):
        return login_page(request)

    @app.post("/login")
    def login(request: Request, password: str = Form("")):
        ip = request.client.host if request.client else "unknown"
        now = time.monotonic()
        tries = [t for t in failures.get(ip, []) if now - t < THROTTLE_WINDOW]
        failures[ip] = tries
        if len(tries) >= THROTTLE_TRIES:
            return login_page(request, "Too many wrong tries. Wait a minute.", 429)
        if hmac.compare_digest(password.encode(), settings.password.encode()):
            failures.pop(ip, None)
            request.session["logged_in"] = True
            return RedirectResponse("/", status_code=303)
        tries.append(now)
        return login_page(request, "Wrong password.")

    @protected.post("/logout")
    def logout(request: Request):
        request.session.clear()
        return RedirectResponse("/login", status_code=303)

    def page(request, name, context):
        return app.state.templates.TemplateResponse(request, name, {"page": name, **context})

    @protected.get("/", response_class=HTMLResponse)
    def cost(request: Request, period: Literal["day", "week", "month"] = "month"):
        gw, orc = app.state.gateway, app.state.openrouter
        now, end = datetime.now(UTC), setup_view.deadline()
        today = now.date()
        got = setup_view.gather({
            "usage": ("gateway", lambda: gw.usage(today - timedelta(days=USAGE_DAYS), today)),
            "models": ("gateway", lambda: gw.model_info()),
            "global_budget": ("gateway", lambda: gw.global_budget()),
            "inference_key": ("openrouter", lambda: orc.inference_key()),
            "credits": ("openrouter", lambda: orc.credits()),
        }, end)
        key = got["inference_key"]
        activity = key if isinstance(key, Unavailable) else setup_view.gather(
            {"activity": ("openrouter", lambda: orc.activity(key["hash"]))}, end)["activity"]
        summary, days = _summary(got, activity, setup_view.gateway_window(app.state.settings), now, period)
        sources_read = not setup_view.missing(got["usage"], got["models"], got["inference_key"], activity)
        return page(request, "cost.html", {
            "s": summary, "days": days, "activity_missing": isinstance(activity, Unavailable),
            "days_unbuilt": summary is not None and days is None and sources_read,
            "period": period, "month": now.strftime("%B").upper(),
            "missing": summary.missing if summary is not None else [],
            # the checks partial's own context
            "price": None, "plan": None, "scope": None, "smoke": None, "error": None,
            "probe_ok": checks.probe_ok,
        })

    @protected.get("/usage", response_class=HTMLResponse)
    def usage(request: Request):
        now = datetime.now(UTC)
        today, gw = now.date(), app.state.gateway
        got = setup_view.gather({
            "usage": ("gateway", lambda: gw.usage(today - timedelta(days=USAGE_DAYS_COMPARED), today)),
            "models": ("gateway", lambda: gw.model_info()),
        }, setup_view.deadline())
        table = None
        if not setup_view.missing(*got.values()):
            try:
                table = usage_tables(got["usage"], got["models"], now)
            except Exception:
                table = None
        bounds = period_bounds(now)
        return page(request, "usage.html", {
            "t": table, "missing": [] if table is not None else ["gateway"],
            "since": {p: bounds[p][0] for p in bounds},
        })

    @protected.get("/setup", response_class=HTMLResponse)
    def setup(request: Request):
        view = setup_view.build(app.state.gateway, app.state.openrouter, app.state.settings)
        return page(request, "setup.html", {"v": view, "missing": view["missing"],
                                             "price_checked": setup_view.latest_price_check()[0]})

    @protected.get("/log", response_class=HTMLResponse)
    def log_page(request: Request):
        entries = _store(store.entries, None)
        return page(request, "log.html", {"entries": entries, "kinds": LOG_KINDS, "missing": []})

    for register in REGISTRARS:
        register(protected, app)
    app.include_router(protected)
    return app


def main() -> FastAPI:
    settings = load_settings(os.environ)
    store.init_db(settings.data_dir / "tower.db")
    return create_app(settings)
