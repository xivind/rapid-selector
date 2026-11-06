"""Settings read from the environment. Secrets are never logged or put in error messages."""

from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

# The order here is the order in which a missing secret is reported.
SECRET_NAMES = (
    "TOWER_PASSWORD",
    "TOWER_SESSION_SECRET",
    "OPENROUTER_MANAGEMENT_KEY",
    "TOWER_GATEWAY_KEY",
    "KEY_SMOKE_TEST",
)


class SettingsError(Exception):
    """A required setting is missing. The message names it, never a value."""


@dataclass(frozen=True)
class Settings:
    password: str = field(repr=False)
    session_secret: str = field(repr=False)
    management_key: str = field(repr=False)
    gateway_key: str = field(repr=False)
    smoke_key: str = field(repr=False)
    gateway_url: str
    openrouter_url: str
    inference_key_name: str
    management_key_expires_at: datetime | None
    data_dir: Path
    config_dir: Path
    management_key_expires_at_invalid: bool = False  # set but not a date; shown on Setup

    def secret_values(self) -> list[str]:
        return [self.password, self.session_secret, self.management_key, self.gateway_key, self.smoke_key]


def _expiry(value: str) -> datetime | None:
    """An ISO date or time, in UTC; None when empty. Raises ValueError when not a date."""
    if not value:
        return None
    parsed = datetime.fromisoformat(value)
    return parsed.replace(tzinfo=UTC) if parsed.tzinfo is None else parsed.astimezone(UTC)


def load_settings(env: Mapping[str, str]) -> Settings:
    for name in SECRET_NAMES:
        if not env.get(name):
            raise SettingsError(f"missing value for {name}")
    try:
        expires, invalid = _expiry(env.get("OPENROUTER_MANAGEMENT_KEY_EXPIRES_AT", "").strip()), False
    except ValueError:  # a typo must not stop tower, and with it the kill switch
        expires, invalid = None, True
    return Settings(
        password=env["TOWER_PASSWORD"],
        session_secret=env["TOWER_SESSION_SECRET"],
        management_key=env["OPENROUTER_MANAGEMENT_KEY"],
        gateway_key=env["TOWER_GATEWAY_KEY"],
        smoke_key=env["KEY_SMOKE_TEST"],
        gateway_url=env.get("TOWER_GATEWAY_URL") or "http://gateway:4000",
        openrouter_url=env.get("OPENROUTER_API_BASE_URL") or "https://openrouter.ai/api/v1",
        inference_key_name=env.get("OPENROUTER_INFERENCE_KEY_NAME") or "rapidselector-gateway",
        management_key_expires_at=expires,
        management_key_expires_at_invalid=invalid,
        data_dir=Path(env.get("TOWER_DATA_DIR") or "/data"),
        config_dir=Path(env.get("TOWER_CONFIG_DIR") or "/config"),
    )
