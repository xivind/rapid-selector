from fastapi.testclient import TestClient

from tower.app import create_app
from tower.settings import load_settings


def test_health():
    settings = load_settings({
        "TOWER_PASSWORD": "a", "TOWER_SESSION_SECRET": "b", "OPENROUTER_MANAGEMENT_KEY": "c",
        "TOWER_GATEWAY_KEY": "d", "KEY_SMOKE_TEST": "e",
    })
    client = TestClient(create_app(settings, start_loop=False))
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
