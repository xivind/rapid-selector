"""Fake OpenAI-compatible upstream standing in for OpenRouter in level 1 tests.

Standard library only. Records every request it receives and can be switched
between success, OpenRouter's refusals and 5xx, with configurable token counts and cost.
"""

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

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

lock = threading.Lock()
state = {"mode": dict(DEFAULT_MODE), "calls_since_mode": 0, "requests": [], "next_id": 1}


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

    def do_GET(self):
        if self.path == "/_requests":
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

        with lock:
            state["requests"].append({"path": self.path, "headers": dict(self.headers), "body": body})
            mode = dict(state["mode"])
            state["calls_since_mode"] += 1
            call_number = state["calls_since_mode"]
            gen_id = f"gen-fake-{state['next_id']}"
            state["next_id"] += 1

        if mode["delay_ms"]:
            time.sleep(mode["delay_ms"] / 1000)

        status = mode["status"]
        if refused(mode, call_number, body):
            code, error = REFUSALS[mode["refusal"]]
            self._send_json(code, {"error": {"code": code, **error}})
            return
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
