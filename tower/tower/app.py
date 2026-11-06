import os

from fastapi import FastAPI

from tower.settings import Settings, load_settings


def create_app(settings: Settings, *, gateway=None, openrouter=None, start_loop: bool = True) -> FastAPI:
    app = FastAPI(title="rapidselector tower")
    app.state.settings = settings

    @app.get("/health")
    def health():
        return {"status": "ok"}

    return app


def main() -> FastAPI:
    return create_app(load_settings(os.environ))
