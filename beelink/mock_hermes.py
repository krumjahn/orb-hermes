#!/usr/bin/env python3
"""Mock OpenAI-compatible Hermes API server, used to test the phone end-to-end."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[mock]", fmt % args, flush=True)

    def _json(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._json({"object": "list", "data": [{"id": "hermes-agent", "object": "model"}]})
            return
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {}
        text = ""
        for message in payload.get("messages", []):
            if message.get("role") == "user":
                text = str(message.get("content", ""))
        print(f"[mock] got: {text!r}", flush=True)
        reply = f"ORB_OK I heard you say: {text}"
        self._json({
            "id": "mock-1",
            "object": "chat.completion",
            "model": payload.get("model", "hermes-agent"),
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": reply},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 10, "total_tokens": 20},
        })


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8642), Handler).serve_forever()
