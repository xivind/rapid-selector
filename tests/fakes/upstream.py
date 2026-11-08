"""Fake OpenAI-compatible upstream standing in for OpenRouter in level 1 tests.

Standard library only. Records every request it receives and can be switched
between success, OpenRouter's refusals and 5xx, with configurable token counts and cost.

Also fakes OpenRouter's management API under /api/v1 (keys, credits, activity, the zero
data retention endpoint list), with shapes from docs/provider-facts.md (2026-11-05).
POST /_openrouter resets that state to its defaults plus the fields given.
"""

import copy
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

DEFAULT_MODE = {
    "status": 200,
    "cost": None,
    "delay_ms": 0,
    "prompt_tokens": 100,
    "completion_tokens": 50,
    "fail_after": None,
    "refusal": None,
    "refuse_first": None,
    "refuse_above_tokens": None,
}

# OpenRouter's documented refusals (https://openrouter.ai/docs/api-reference/limits, 2026-11-04).
REFUSALS = {
    None: (402, {"message": "Insufficient credits"}),
    "in_flight": (402, {
        "message": "This request would exceed your available credits given your current in-flight requests.",
        "metadata": {"reason": "in_flight_budget_exhausted", "limit_source": "openrouter_in_flight_budget"},
    }),
    "weight": (402, {
        "message": "This request is too expensive for your in-flight budget.",
        "metadata": {"reason": "weight_exceeds_budget", "limit_source": "openrouter_credits"},
    }),
    "key_limit_402": (402, {
        "message": "Key limit exceeded.",
        "metadata": {"limit_source": "openrouter_key_limit"},
    }),
    "key_limit_403": (403, {
        "message": "Key limit exceeded.",
        "metadata": {"limit_source": "openrouter_key_limit", "scope": "key_limit"},
    }),
}

MANAGEMENT_KEY = os.environ.get("FAKE_MANAGEMENT_KEY", "test-management-key")
INFERENCE_KEY_NAME = os.environ.get("FAKE_INFERENCE_KEY_NAME", "rapidselector-gateway")
GATEWAY_CONFIG = os.environ.get("FAKE_GATEWAY_CONFIG", "/config/config.yaml")
INFERENCE_KEY_HASH = "f01d52606dc8f0a8303a7b5cc3fa07109c2e346cec7c0a16b40de462992ce943"
# OpenRouter's documented 401 for a disabled or invalid key (https://openrouter.ai/docs/api-reference/errors,
# 2026-11-06); the exact message for a disabled key is not documented.
DISABLED_KEY_ERROR = {"code": 401, "message": "Invalid credentials", "metadata": {"error_type": "authentication"}}


def zdr_from_config(path):
    """One endpoint per gateway/config.yaml entry, at the config's price, as tests/checks.bats builds it."""
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return []
    out, entry = [], None
    for line in lines + ["  - model_name: end"]:
        if re.match(r"\s*- model_name:", line):
            if entry and entry.get("model_id"):
                out.append({"model_id": entry["model_id"], "tag": entry.get("tag"), "service_tier": None,
                            "safety_retention": False,
                            "pricing": {"prompt": entry.get("prompt"), "completion": entry.get("completion")}})
            entry = {}
            continue
        field = re.match(r"\s*(model|input_cost_per_token|output_cost_per_token|order):\s*(.*)", line)
        if entry is None or not field:
            continue
        name, value = field.groups()
        if name == "model" and value.startswith("openrouter/"):
            entry["model_id"] = value.removeprefix("openrouter/")
        elif name == "input_cost_per_token":
            entry["prompt"] = repr(float(value))
        elif name == "output_cost_per_token":
            entry["completion"] = repr(float(value))
        elif name == "order":
            entry["tag"] = json.loads(value)[0]
    return out


def default_openrouter():
    return {
        "keys": [{
            "hash": INFERENCE_KEY_HASH, "name": INFERENCE_KEY_NAME, "label": "sk-or-v1-0e6...1c96",
            "disabled": False, "limit": 20, "limit_remaining": 20, "limit_reset": "monthly",
            "include_byok_in_limit": False, "usage": 0, "usage_daily": 0, "usage_weekly": 0, "usage_monthly": 0,
            "byok_usage": 0, "byok_usage_daily": 0, "byok_usage_weekly": 0, "byok_usage_monthly": 0,
            "created_at": "2026-11-01T00:00:00Z", "updated_at": None, "last_used_at": None, "expires_at": None,
        }],
        "credits": {"total_credits": 20, "total_usage": 0},
        "activity": [],
        "zdr": copy.deepcopy(ZDR),
        "fail": None,  # "keys" | "key" | "credits" | "activity" | "zdr" | "patch": that route answers 500
    }


ZDR = zdr_from_config(GATEWAY_CONFIG)
lock = threading.Lock()
state = {"mode": dict(DEFAULT_MODE), "calls_since_mode": 0, "requests": [], "next_id": 1,
         "openrouter": default_openrouter(), "or_requests": []}


def refused(mode, call_number, body):
    """Whether this call gets the mode's refusal."""
    return (
        mode["status"] == 402
        or (mode["fail_after"] is not None and call_number > mode["fail_after"])
        or (mode["refuse_first"] is not None and call_number <= mode["refuse_first"])
        or (mode["refuse_above_tokens"] is not None and body.get("max_tokens", 0) > mode["refuse_above_tokens"])
    )


def usage_for(mode):
    usage = {
        "prompt_tokens": mode["prompt_tokens"],
        "completion_tokens": mode["completion_tokens"],
        "total_tokens": mode["prompt_tokens"] + mode["completion_tokens"],
    }
    if mode["cost"] is not None:
        usage["cost"] = mode["cost"]
    return usage


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {"_raw": raw.decode("utf-8", "replace")}

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _management(self, method, body=None):
        """OpenRouter's management API. Returns False when the path is not one of its routes."""
        url = urlsplit(self.path)
        query = parse_qs(url.query)
        path = url.path.removeprefix("/api/v1")
        routes = {"/keys": "keys", "/credits": "credits", "/activity": "activity", "/endpoints/zdr": "zdr"}
        if not url.path.startswith("/api/v1/"):
            return False
        if method == "GET" and path in routes:
            route = routes[path]
        elif re.fullmatch(r"/keys/[^/]+", path):
            route = "patch" if method == "PATCH" else "key"
        else:
            return False
        authorised = self.headers.get("Authorization") == f"Bearer {MANAGEMENT_KEY}"
        with lock:
            state["or_requests"].append({"method": method, "path": url.path, "authorised": authorised,
                                         "body": body, "at": time.time()})
            orstate = state["openrouter"]
            if route != "zdr" and not authorised:
                self._send_json(401, {"error": {"code": 401, "message": "Invalid credentials"}})
                return True
            if orstate["fail"] == route:
                self._send_json(500, {"error": {"code": 500, "message": "Fake OpenRouter error"}})
                return True
            if route == "keys":
                keys = orstate["keys"]
                if query.get("include_disabled", ["false"])[0] != "true":
                    keys = [k for k in keys if not k.get("disabled")]
                self._send_json(200, {"data": keys})
            elif route in ("key", "patch"):
                key = next((k for k in orstate["keys"] if k["hash"] == path.removeprefix("/keys/")), None)
                if key is None:
                    self._send_json(404, {"error": {"code": 404, "message": "Not found"}})
                    return True
                if route == "patch" and "disabled" in (body or {}):
                    key["disabled"] = bool(body["disabled"])
                    key["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                self._send_json(200, {"data": key})
            elif route == "credits":
                self._send_json(200, {"data": orstate["credits"]})
            elif route == "activity":
                self._send_json(200, {"data": orstate["activity"]})
            else:
                self._send_json(200, {"data": orstate["zdr"]})
        return True

    def do_PATCH(self):
        if not self._management("PATCH", self._read_json()):
            self._send_json(404, {"error": "not found"})

    def do_GET(self):
        if self._management("GET"):
            return
        if self.path == "/_openrouter/requests":
            with lock:
                self._send_json(200, state["or_requests"])
        elif self.path == "/_requests":
            with lock:
                self._send_json(200, state["requests"])
        elif self.path == "/health":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"error": "not found"})

    def do_DELETE(self):
        if self.path == "/_requests":
            with lock:
                state["requests"].clear()
            self._send_json(200, {"cleared": True})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        body = self._read_json()
        if self.path == "/_mode":
            with lock:
                state["mode"] = {**DEFAULT_MODE, **{k: v for k, v in body.items() if k in DEFAULT_MODE}}
                state["calls_since_mode"] = 0
            self._send_json(200, state["mode"])
            return
        if self.path == "/_openrouter":
            with lock:
                fresh = default_openrouter()
                state["openrouter"] = {**fresh, **{k: v for k, v in body.items() if k in fresh}}
                state["or_requests"].clear()
            self._send_json(200, {"ok": True})
            return

        with lock:
            state["requests"].append({"path": self.path, "headers": dict(self.headers), "body": body, "at": time.time()})
            mode = dict(state["mode"])
            state["calls_since_mode"] += 1
            call_number = state["calls_since_mode"]
            gen_id = f"gen-fake-{state['next_id']}"
            state["next_id"] += 1

        with lock:
            disabled = any(k.get("disabled") for k in state["openrouter"]["keys"] if k.get("name") == INFERENCE_KEY_NAME)
        if disabled:
            self._send_json(401, {"error": DISABLED_KEY_ERROR})
            return
        status = mode["status"]
        if refused(mode, call_number, body):
            code, error = REFUSALS[mode["refusal"]]
            self._send_json(code, {"error": {"code": code, **error}})
            return
        if mode["delay_ms"]:
            time.sleep(mode["delay_ms"] / 1000)
        if status != 200:
            self._send_json(status, {"error": {"code": status, "message": "Fake upstream error"}})
            return
        if not self.path.endswith("/chat/completions"):
            self._send_json(404, {"error": {"code": 404, "message": "Unknown path"}})
            return

        model = body.get("model", "")
        if body.get("stream"):
            self._stream(gen_id, model, mode)
            return
        self._send_json(200, {
            "id": gen_id,
            "object": "chat.completion",
            "created": int(time.time()),
            "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "fake reply"}, "finish_reason": "stop"}],
            "usage": usage_for(mode),
        })

    def _stream(self, gen_id, model, mode):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        base = {"id": gen_id, "object": "chat.completion.chunk", "created": int(time.time()), "model": model}
        chunks = [
            {**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": "fake reply"}, "finish_reason": None}]},
            {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
            {**base, "choices": [], "usage": usage_for(mode)},
        ]
        for chunk in chunks:
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
