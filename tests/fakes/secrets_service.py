"""Fake secrets-service for level 1 tests of rapidselector.sh.

Standard library only. Serves GET /secrets/rapidselector from the JSON file at
$FAKE_SECRETS_FILE for the bearer token "test-token".
"""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "test-token"
state = {"status": 200}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
            return
        if self.path != "/secrets/rapidselector":
            self._send_json(404, {"detail": "unknown secret"})
            return
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            self._send_json(401, {"detail": "invalid token"})
            return
        if state["status"] != 200:
            self._send_json(state["status"], {"detail": "forced status"})
            return
        with open(os.environ["FAKE_SECRETS_FILE"], encoding="utf-8") as f:
            blob = json.load(f)
        self._send_json(200, {"name": "rapidselector", "blob": blob})

    def do_POST(self):
        if self.path != "/_status":
            self._send_json(404, {"detail": "not found"})
            return
        length = int(self.headers.get("Content-Length") or 0)
        state["status"] = int(json.loads(self.rfile.read(length) or b"{}").get("status", 200))
        self._send_json(200, state)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8002), Handler).serve_forever()
