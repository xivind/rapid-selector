from datetime import UTC, datetime

import pytest

from tower.settings import SettingsError, load_settings

SECRETS = {
    "TOWER_PASSWORD": "pw-value",
    "TOWER_SESSION_SECRET": "session-value",
    "OPENROUTER_MANAGEMENT_KEY": "mgmt-value",
    "TOWER_GATEWAY_KEY": "sk-gateway-value",
    "KEY_SMOKE_TEST": "sk-smoke-value",
}


def test_missing_secret_names_it():
    env = {k: v for k, v in SECRETS.items() if k != "OPENROUTER_MANAGEMENT_KEY"}
    with pytest.raises(SettingsError) as err:
        load_settings(env)
    text = str(err.value)
    assert "OPENROUTER_MANAGEMENT_KEY" in text
    for value in env.values():
        assert value not in text


def test_defaults():
    s = load_settings(SECRETS)
    assert s.gateway_url == "http://gateway:4000"
    assert s.openrouter_url == "https://openrouter.ai/api/v1"
    assert s.inference_key_name == "rapidselector-gateway"
    assert s.management_key_expires_at is None


def test_expiry_parsed():
    s = load_settings({**SECRETS, "OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT": "2027-11-06"})
    assert s.management_key_expires_at == datetime(2027, 11, 6, tzinfo=UTC)


def test_secret_values_lists_all_secrets():
    assert sorted(load_settings(SECRETS).secret_values()) == sorted(SECRETS.values())
