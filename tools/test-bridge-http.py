#!/usr/bin/env python3
"""
test-bridge-http.py - the bridge over real HTTP, with a fake hermes CLI.

The bridge is started as a process with a fake "hermes" on its PATH, so both
the good and the broken output of the CLI can be tested without a real agent:

  * a good answer has to come back as just the answer - the orb reads it out
    loud, so the CLI's chrome must never reach it
  * a failed agent has to be a failure, not an answer - the CLI exits with 0
    even when the agent broke, so the text is what decides
"""
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "beelink", "hermes_bridge.py")
TOKEN = "test-token"

FAILURES = 0


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


GOOD_OUTPUT = """Query: \n\nReply with exactly: HELLO\n\n
────────────────────────────────────────
☤ Hermes
HELLO
────────────────────────────────────────

Resume this session with:
  hermes --resume local-abc

Session:        local-abc
Duration:       10s
Messages:       2 (1 user, 0 tool calls)
"""

BROKEN_OUTPUT = """🤖 AI Agent with Tool Calling
==================================================
🤖 AI Agent initialized with model:
🔑 Using API key: no-key-required
📊 Context limit: 256,000 tokens

📝 User Query: Reply with exactly: HELLO

==================================================
💻 Starting conversation: '...'

🔄 Making API call #1/10...
⚠️ Attempt 1/3, not retryable failed: HTTP 400: model is required
❌ OpenRouter rejected the request and retrying won't help: HTTP 400: model is required

📋 CONVERSATION SUMMARY
==================================================
✅ Completed: False
📎 API Calls: 1
💬 Messages: 1

🎯 FINAL RESPONSE:
------------------------------
OpenRouter rejected this request as malformed, so the model didn't answer.

Provider said: HTTP 400: model is required

🏁 Agent execution completed!
"""


def write_fake_hermes(directory, output):
    """A fake hermes CLI that prints the given output."""
    payload = os.path.join(directory, "payload.txt")
    with open(payload, "w", encoding="utf-8") as handle:
        handle.write(output)
    script = os.path.join(directory, "hermes")
    with open(script, "w", encoding="utf-8") as handle:
        handle.write(
            "#!/bin/sh\n"
            f"cat '{payload}'\n"
            "exit 0\n"
        )
    os.chmod(script, 0o755)


def main():
    print("BRIDGE OVER HTTP")
    port = free_port()
    work = tempfile.mkdtemp(prefix="bridge-http-")
    write_fake_hermes(work, GOOD_OUTPUT)

    env = dict(os.environ)
    env["PATH"] = work + os.pathsep + env.get("PATH", "")
    env["BRIDGE_HOST"] = "127.0.0.1"
    env["BRIDGE_PORT"] = str(port)
    env["BRIDGE_TOKEN"] = TOKEN
    env["HERMES_PREFER"] = "auto"
    # Ollama is not running here: the agent has to be the one that answers
    env["OLLAMA_URL"] = "http://127.0.0.1:1"

    proc = subprocess.Popen(
        [sys.executable, BRIDGE],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        # wait for the port
        deadline = time.time() + 20
        up = False
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=1):
                    up = True
                    break
            except OSError:
                time.sleep(0.2)
        if not up:
            print("  the bridge did not start")
            print(proc.stdout.read() if proc.stdout else "")
            return 1

        status, body = request(port, "GET", "/health")
        health = json.loads(body)
        check("the health endpoint answers", status == 200, f"HTTP {status}")
        check("the bridge reports its version", bool(health.get("bridge")),
              f"bridge={health.get('bridge')!r}")

        # a good answer comes back as just the answer
        status, body = request(port, "POST", "/chat",
                                {"text": "Reply with exactly: HELLO", "session": "test"})
        payload = json.loads(body) if body.strip().startswith("{") else {}
        reply = payload.get("reply", "")
        check("a good answer is just the answer", status == 200 and reply == "HELLO",
              f"HTTP {status} reply={reply!r}")
        check("the CLI chrome is gone",
              "☤ Hermes" not in reply and "Resume this session" not in reply,
              repr(reply[:120]))

        # a broken agent is a failure, not an answer
        write_fake_hermes(work, BROKEN_OUTPUT)
        status, body = request(port, "POST", "/chat",
                                {"text": "Reply with exactly: HELLO", "session": "test"})
        chrome = ("AI Agent with Tool Calling", "OpenRouter rejected",
                  "FINAL RESPONSE:", "Agent execution completed!", "Making API call")
        check("the agent's report never reaches the caller",
              not any(marker in body for marker in chrome),
              f"HTTP {status} body={body[:120]!r}")
        check("a broken agent does not look like a good answer", status != 200,
              f"HTTP {status}")

        # and the health endpoint now says what went wrong
        status, body = request(port, "GET", "/health")
        health = json.loads(body)
        check("the health endpoint reports the agent's error",
              "model is required" in (health.get("hermes_error") or ""),
              f"hermes_error={health.get('hermes_error')!r}")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()

    print()
    if FAILURES:
        print(f"BRIDGE OVER HTTP: {FAILURES} FAILURE(S)")
        return 1
    print("ALL BRIDGE HTTP TESTS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
