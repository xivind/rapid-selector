import hmac
import os
import time
from collections.abc import Callable
from pathlib import Path

from fastapi import APIRouter, Depends, FastAPI, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware

from tower.settings import Settings, load_settings

HERE = Path(__file__).parent
SESSION_MAX_AGE = 30 * 24 * 3600
THROTTLE_TRIES = 5
THROTTLE_WINDOW = 60.0


REGISTRARS: list[Callable[[APIRouter, FastAPI], None]] = []


def require_login(request: Request) -> None:
    """Dependency for every route except /health, /metrics, /login and /static."""
    if request.session.get("logged_in"):
        return
    if request.method == "GET":
        raise HTTPException(status_code=303, headers={"Location": "/login"})
    raise HTTPException(status_code=401, detail="login required")


def create_app(settings: Settings, *, gateway=None, openrouter=None, start_loop: bool = True) -> FastAPI:
    app = FastAPI(title="rapidselector tower", docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = settings
    app.state.templates = Jinja2Templates(directory=HERE / "templates")
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

    @protected.get("/", response_class=HTMLResponse)
    def index(request: Request):
        return app.state.templates.TemplateResponse(request, "base.html", {})

    for register in REGISTRARS:
        register(protected, app)
    app.include_router(protected)
    return app


def main() -> FastAPI:
    return create_app(load_settings(os.environ))
