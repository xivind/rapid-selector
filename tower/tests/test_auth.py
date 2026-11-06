import hmac
import time

import pytest
from fastapi.testclient import TestClient

from tower.app import create_app
from tower.settings import load_settings


@pytest.fixture
def client():
    settings = load_settings({
        "TOWER_PASSWORD": "right", "TOWER_SESSION_SECRET": "s3", "OPENROUTER_MANAGEMENT_KEY": "c",
        "TOWER_GATEWAY_KEY": "d", "KEY_SMOKE_TEST": "e",
    })
    return TestClient(create_app(settings, start_loop=False), follow_redirects=False)


def test_pages_redirect_to_login(client):
    response = client.get("/")
    assert response.status_code in (302, 303)
    assert response.headers["location"] == "/login"


def test_wrong_password_refused(client):
    response = client.post("/login", data={"password": "wrong"})
    assert response.status_code == 200
    assert "Wrong password" in response.text
    assert "tower_session" not in client.cookies
    assert client.get("/").status_code in (302, 303)


def test_right_password_logs_in(client):
    response = client.post("/login", data={"password": "right"})
    assert response.status_code in (302, 303)
    assert "tower_session" in client.cookies
    page = client.get("/")
    assert page.status_code == 200
    assert 'id="killswitch"' in page.text


def test_password_compared_in_constant_time(client, monkeypatch):
    calls = []
    real = hmac.compare_digest

    def spy(a, b):
        calls.append(1)
        return real(a, b)

    monkeypatch.setattr(hmac, "compare_digest", spy)
    client.post("/login", data={"password": "wrong"})
    assert calls


def test_login_throttled(client, monkeypatch):
    now = [1000.0]
    monkeypatch.setattr(time, "monotonic", lambda: now[0])
    for _ in range(5):
        assert client.post("/login", data={"password": "wrong"}).status_code == 200
        now[0] += 1
    assert client.post("/login", data={"password": "right"}).status_code == 429
    now[0] = 1000.0 + 60.5
    assert client.post("/login", data={"password": "right"}).status_code in (302, 303)


def test_post_without_session_is_401(client):
    assert client.post("/logout").status_code == 401


def test_health_and_static_open(client):
    assert client.get("/health").status_code == 200
    assert client.get("/static/tower.css").status_code == 200


def test_logout_clears_session(client):
    client.post("/login", data={"password": "right"})
    assert client.post("/logout").status_code in (302, 303)
    assert client.get("/").status_code in (302, 303)
