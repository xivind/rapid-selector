"""Clients for the LiteLLM gateway and OpenRouter's management API.

Errors name the source and a status or error class, never a header, key or URL.
"""

import hashlib
import logging
import time
from dataclasses import dataclass
from datetime import date, datetime

import httpx

log = logging.getLogger("tower.clients")
# httpx logs every request URL at INFO, and query strings can hold a key.
logging.getLogger("httpx").setLevel(logging.WARNING)

READ_TIMEOUT = 5.0
WRITE_TIMEOUT = 15.0


class Unavailable(Exception):
    def __init__(self, source: str, reason: str):
        super().__init__(f"{source} unavailable: {reason}")
        self.source = source
        self.reason = reason


@dataclass
class GatewayKey:
    token_hash: str
    alias: str | None
    team_id: str | None
    blocked: bool


@dataclass
class UsageRow:
    day: date
    name: str
    key_alias: str | None
    calls: int
    tokens_in: int
    tokens_out: int
    spend_usd: float


class _Base:
    source = ""

    def __init__(self, base_url, headers, http, ttl, clock):
        self._base = base_url.rstrip("/")
        self._headers = headers
        self._http = http
        self._ttl = ttl
        self._clock = clock
        self._cache: dict = {}

    def _request(self, method, path, params=None, json=None, auth=True, write=False):
        try:
            resp = self._http.request(
                method,
                self._base + path,
                params=params,
                json=json,
                headers=self._headers if auth else None,
                timeout=WRITE_TIMEOUT if write else READ_TIMEOUT,
            )
        except httpx.HTTPError as e:
            log.warning("%s request failed: %s", self.source, type(e).__name__)
            raise Unavailable(self.source, type(e).__name__) from None
        if resp.status_code >= 400:
            log.warning("%s answered HTTP %s for %s %s", self.source, resp.status_code, method, path)
            raise Unavailable(self.source, f"HTTP {resp.status_code}")
        try:
            return resp.json() if resp.content else {}
        except ValueError:
            raise Unavailable(self.source, "invalid JSON") from None

    def _get(self, path, params=None, auth=True):
        key = (path, tuple(sorted((params or {}).items())), auth)
        hit = self._cache.get(key)
        if hit and self._clock() - hit[0] < self._ttl:
            return hit[1]
        data = self._request("GET", path, params, auth=auth)
        self._cache[key] = (self._clock(), data)
        return data

    def _write(self, method, path, json):
        self._cache.clear()
        self._request(method, path, json=json, write=True)
        self._cache.clear()


class GatewayClient(_Base):
    source = "gateway"

    def __init__(self, base_url, key, http, ttl=30, clock=time.monotonic):
        super().__init__(base_url, {"Authorization": f"Bearer {key}"}, http, ttl, clock)
        self._key = key

    def own_hash(self) -> str:
        return hashlib.sha256(self._key.encode()).hexdigest()

    def model_info(self) -> list[dict]:
        return self._get("/model/info").get("data", [])

    def keys(self) -> list[GatewayKey]:
        out, page = [], 1
        while True:
            body = self._get("/key/list", {"return_full_object": "true", "page": page})
            out += [
                GatewayKey(k["token"], k.get("key_alias"), k.get("team_id"), bool(k.get("blocked")))
                for k in body.get("keys", [])
            ]
            if page >= (body.get("total_pages") or 1):
                return out
            page += 1

    def block(self, token_hash: str) -> None:
        self._write("POST", "/key/block", {"key": token_hash})

    def unblock(self, token_hash: str) -> None:
        self._write("POST", "/key/unblock", {"key": token_hash})

    def team(self, team_id: str) -> dict:
        return self._get("/team/info", {"team_id": team_id})

    def key(self, alias_or_hash: str) -> dict:
        return self._get("/key/info", {"key": alias_or_hash})

    def global_budget(self) -> float | None:
        value = self._get("/global/spend").get("max_budget")
        return None if value is None else float(value)

    def retention(self) -> str | None:
        body = self._get("/config/field/info", {"field_name": "maximum_spend_logs_retention_period"})
        return body.get("field_value")

    def usage(self, start: date, end: date) -> list[UsageRow]:
        rows, page = [], 1
        while True:
            body = self._get(
                "/user/daily/activity",
                {"start_date": start.isoformat(), "end_date": end.isoformat(), "page": page},
            )
            for day in body.get("results", []):
                d = date.fromisoformat(day["date"])
                for name, group in day.get("breakdown", {}).get("model_groups", {}).items():
                    for entry in group.get("api_key_breakdown", {}).values():
                        m = entry.get("metrics", {})
                        rows.append(
                            UsageRow(
                                d,
                                name,
                                (entry.get("metadata") or {}).get("key_alias"),
                                int(m.get("successful_requests") or 0),
                                int(m.get("prompt_tokens") or 0),
                                int(m.get("completion_tokens") or 0),
                                float(m.get("spend") or 0.0),
                            )
                        )
            meta = body.get("metadata") or {}
            if not meta.get("has_more") or page >= (meta.get("total_pages") or 1):
                return rows
            page += 1


class OpenRouterClient(_Base):
    source = "openrouter"

    def __init__(self, base_url, management_key, inference_key_name, http, ttl=30, clock=time.monotonic):
        super().__init__(base_url, {"Authorization": f"Bearer {management_key}"}, http, ttl, clock)
        self._name = inference_key_name

    def inference_key(self) -> dict:
        # The list leaves disabled keys out unless asked, and level 2 disables this one.
        for entry in self._get("/keys", {"include_disabled": "true"}).get("data", []):
            if entry.get("name") == self._name:
                detail = self._get(f"/keys/{entry['hash']}").get("data", {})
                return {**detail, "hash": entry["hash"]}
        raise Unavailable(self.source, f"no key named {self._name}")

    def management_key_expiry(self) -> datetime | None:
        # The docs do not say how a management key is told apart in the key list,
        # so there is nothing to read here. Settings' management_key_expires_at is used instead.
        return None

    def credits(self) -> dict:
        return self._get("/credits").get("data", {})

    def activity(self, key_hash: str) -> list[dict]:
        return self._get("/activity", {"api_key_hash": key_hash}).get("data", [])

    def zdr_endpoints(self) -> list[dict]:
        return self._get("/endpoints/zdr", auth=False).get("data", [])

    def set_disabled(self, key_hash: str, disabled: bool) -> None:
        self._write("PATCH", f"/keys/{key_hash}", {"disabled": disabled})
