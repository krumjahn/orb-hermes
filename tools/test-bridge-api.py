#!/usr/bin/env python3
"""
test-bridge-api.py - the bridge talking to a Hermes API server.

The API server is the fast way to reach the agent: it keeps the model and
the tools loaded, so a question is answered in seconds instead of minutes.

It needs a key, and that is exactly where this went wrong before: the
bridge probed the server without the key, the server refused, and a refusal
looks precisely like a server that is not there. So the orb went on using
the CLI, which starts a fresh agent for every question.

So this checks:

  * the probe carries the key, and the server is found
  * the chat request carries the key too
  * the session goes with the request, so the agent remembers the question
  * the model that is asked for is one the server actually serves
  * without the key the server is NOT reachable - so a missing key is a
    clear fault and not a slow one
"""
import http.client
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "beelink", "hermes_bridge.py")
TOKEN = "test-token"
API_KEY = "a-key-the-server-expects"

FAILURES = 0
SEEN = {"auth": [], "session": [], "model": [], "paths": []}


def check(label, ok, detail=""):
    global FAILURES
    print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  {detail}" if detail else ""))
    if not ok:
        FAILURES += 1


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def request(port, method, path, body=None, timeout=30):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    headers = {"X-Auth-Token": TOKEN}
    payload = None
    if body is not None:
        payload = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    try:
        conn.request(method, path, body=payload, headers=headers)
        response = conn.getresponse()
        return response.status, response.read().decode("utf-8", "replace")
    finally:
        conn.close()


class FakeApi(http.server.BaseHTTPRequestHandler):
    """An OpenAI-compatible server that insists on its key."""

    def log_message(self, *args):
        pass

    def _refuse(self):
        body = b'{"error":"no key"}'
        self.send_response(401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        SEEN["auth"].append(self.headers.get("Authorization"))
        SEEN["paths"].append(self.path)
        if self.headers.get("Authorization") != f"Bearer {API_KEY}":
            self._refuse()
            return False
        return True

    def do_GET(self):
        if not self._authed():
            return
        if self.path.rstrip("/").endswith("/models"):
            body = json.dumps({"data": [{"id": "memory"}, {"id": "other"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        if not self._authed():
            return
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except ValueError:
            payload = {}
        SEEN["model"].append(payload.get("model"))
        SEEN["session"].append(self.headers.get("X-Hermes-Session-Id"))
        body = json.dumps(
            {"choices": [{"message": {"content": "HELLO FROM THE API SERVER"}}]}
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def start_bridge(port, api_url, api_key):
    env = dict(os.environ)
    env["BRIDGE_HOST"] = "127.0.0.1"
    env["BRIDGE_PORT"] = str(port)
    env["BRIDGE_TOKEN"] = TOKEN
    env["HERMES_PREFER"] = "auto"
    env["HERMES_BASE_URL"] = api_url
    env["OLLAMA_URL"] = "http://127.0.0.1:1"
    if api_key:
        env["HERMES_API_KEY"] = api_key
    else:
        env.pop("HERMES_API_KEY", None)
    # no hermes CLI on the PATH: the API server has to be the one that answers
    proc = subprocess.Popen(
        [sys.executable, BRIDGE],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    deadline = time.time() + 25
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return proc
        except OSError:
            time.sleep(0.2)
    return proc


def stop(proc):
    try:
        proc.terminate()
        proc.wait(timeout=10)
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass


def main():
    print("BRIDGE AND THE HERMES API SERVER")

    api_port = free_port()
    api = http.server.ThreadingHTTPServer(("127.0.0.1", api_port), FakeApi)
    threading.Thread(target=api.serve_forever, daemon=True).start()

    port = free_port()
    proc = start_bridge(port, f"http://127.0.0.1:{api_port}/v1", API_KEY)
    try:
        # 1. the health endpoint says the API server is there
        status, body = request(port, "GET", "/health")
        check("the health endpoint answers", status == 200, f"HTTP {status}")
        health = json.loads(body)
        info = health.get("hermes_api") or {}
        check(
            "the bridge finds the API server",
            info.get("reachable") is True,
            f"reachable={info.get('reachable')}",
        )
        check("the key is seen", info.get("key_set") is True)
        check(
            "the models the server serves are read",
            "memory" in (info.get("models") or []),
            str(info.get("models")),
        )

        # 2. the probe carried the key - the server refuses without it
        check(
            "the probe carries the key",
            all(auth == f"Bearer {API_KEY}" for auth in SEEN["auth"] if auth),
            f"{len(SEEN['auth'])} request(s)",
        )
        check(
            "the server was asked for its model list",
            any(p.endswith("/models") for p in SEEN["paths"]),
        )

        # 3. a question goes to the API server
        status, body = request(
            port,
            "POST",
            "/chat",
            {"text": "Reply with exactly: HELLO", "session": "session-123"},
        )
        check("the chat answers", status == 200, f"HTTP {status}")
        reply = json.loads(body).get("reply", "")
        check(
            "the answer is the API server's",
            reply == "HELLO FROM THE API SERVER",
            repr(reply[:80]),
        )
        check(
            "the bridge used the API server",
            json.loads(request(port, "GET", "/health")[1]).get("hermes") == "api-server",
            "backend="
            + str(json.loads(request(port, "GET", "/health")[1]).get("hermes")),
        )
        check(
            "the model asked for is one the server serves",
            "memory" in (SEEN["model"] or []),
            str(SEEN["model"]),
        )
        check(
            "the session goes with the question",
            "session-123" in (SEEN["session"] or []),
            str(SEEN["session"]),
        )
        check(
            "the chat request carries the key",
            all(auth == f"Bearer {API_KEY}" for auth in SEEN["auth"] if auth),
        )
    finally:
        stop(proc)
        api.shutdown()

    # 4. without the key the server is not reachable - a missing key must be
    #    a clear fault and not a slow one
    port = free_port()
    proc = start_bridge(port, f"http://127.0.0.1:{api_port}/v1", "")
    try:
        status, body = request(port, "GET", "/health")
        health = json.loads(body)
        info = health.get("hermes_api") or {}
        check(
            "without the key the API server is not reachable",
            info.get("reachable") is False,
            f"reachable={info.get('reachable')}",
        )
        check("without the key the bridge says so", info.get("key_set") is False)
    finally:
        stop(proc)
        api.shutdown()

    print()
    if FAILURES:
        print(f"BRIDGE API SERVER: {FAILURES} FAILURES")
        return 1
    print("ALL BRIDGE API SERVER TESTS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
