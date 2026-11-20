#!/usr/bin/env python3
"""
test-relay.py - check the phone <-> Mac <-> Beelink relay.

Two bugs live in this path and both are invisible until they bite:

1. The dialer used a 15 s socket timeout for the bridge, so a 27B model that
   needed 16 s to answer was cut off and the relay answered the phone with
   its own "502 Bad Gateway".
2. When a dialer disconnected, the relay cleared the channel even if a newer
   dialer had already taken it over - which left the relay attached to a
   dead socket and the live dialer waiting forever.

The test starts a slow stand-in bridge, the relay and a dialer, and then
checks that a slow answer arrives intact and that the relay survives a
dialer being replaced.
"""
import http.client
import os
import signal
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BEELINK = os.environ.get("ORB_BEELINK_DIR", os.path.join(HERE, "beelink"))
TOKEN = "relay-test-token"

FAILURES = 0


def check(label, ok, detail=""):
    global FAILURES
    if ok:
        print(f"  PASS  {label}")
    else:
        FAILURES += 1
        print(f"  FAIL  {label}  {detail}")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for_port(port, timeout=15):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return True
        except OSError:
            time.sleep(0.2)
    return False


class FakeBridge(threading.Thread):
    """A stand-in for the Beelink's bridge that answers slowly."""

    daemon = True

    def __init__(self, port, delay):
        super().__init__()
        self.port = port
        self.delay = delay
        self.sock = socket.socket()
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(("127.0.0.1", port))
        self.sock.listen(8)
        self.running = True

    def run(self):
        while self.running:
            try:
                client, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(client,), daemon=True).start()

    def serve(self, client):
        try:
            client.settimeout(10)
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = client.recv(65536)
                if not chunk:
                    return
                data += chunk
            head, rest = data.split(b"\r\n\r\n", 1)
            length = 0
            for line in head.decode(errors="replace").split("\r\n"):
                if line.lower().startswith("content-length:"):
                    length = int(line.split(":", 1)[1].strip())
            while len(rest) < length:
                chunk = client.recv(65536)
                if not chunk:
                    break
                rest += chunk
            time.sleep(self.delay)
            body = b'{"reply": "the slow answer"}'
            client.sendall(
                b"HTTP/1.0 200 OK\r\n"
                b"Content-Type: application/json\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
            )
        except OSError:
            pass
        finally:
            try:
                client.close()
            except OSError:
                pass

    def stop(self):
        self.running = False
        try:
            self.sock.close()
        except OSError:
            pass


class FlakyBridge(FakeBridge):
    """A bridge that answers with the dialer's 502 the first few times.

    This is what the Beelink does when its model is cold: the dialer's read
    window runs out before the answer is ready and it answers with a 502 of
    its own. The model is warm by the next attempt, so the retry gets the
    real answer.
    """

    def __init__(self, port, fail_first=2):
        super().__init__(port, delay=0)
        self.fail_first = fail_first
        self.served = 0

    def serve(self, client):
        self.served += 1
        if self.served <= self.fail_first:
            try:
                client.settimeout(10)
                body = b""
                client.sendall(
                    b"HTTP/1.0 502 Bad Gateway\r\n"
                    b"Content-Length: 0\r\n\r\n"
                )
            except OSError:
                pass
            finally:
                try:
                    client.close()
                except OSError:
                    pass
            return
        super().serve(client)


def ask(port, path="/chat", body='{"text":"hello"}', timeout=90):
    """Ask the relay. A broken relay may drop the connection outright."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        conn.request("POST", path, body=body, headers={
            "Content-Type": "application/json",
            "X-Auth-Token": TOKEN,
        })
        response = conn.getresponse()
        return response.status, response.read()
    except Exception as exc:  # noqa: BLE001 - the failure is the result
        return 0, f"ERROR: {type(exc).__name__}: {exc}".encode()
    finally:
        conn.close()


def start(script, *args):
    return subprocess.Popen(
        [sys.executable, os.path.join(BEELINK, script), *[str(a) for a in args]],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


def stop(process):
    if process and process.poll() is None:
        process.send_signal(signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


def check_time_context():
    """The relay hands the model the weekday, so it never has to derive it.

    Given only a date, the model called November 17 a Monday.
    """
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "relay_mac_module", os.path.join(BEELINK, "relay_mac.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    stamp = module.local_time_line(now="2026-11-17 14:35:00", zone="Asia/Hong_Kong")
    check("the weekday is added to the time context",
          "Tuesday, 2026-11-17" in stamp, stamp)

    already = module.local_time_line(now="Tuesday, 2026-11-17 14:35:00 HKT")
    check("a stamp that already names the weekday is left alone",
          already.count("Tuesday") == 1, already)

    dated = module.local_time_line(now="2026-11-17")
    check("a bare date also gets its weekday", dated.startswith("[current local time: Tuesday,"), dated)


def check_stale_replies():
    """A reply nobody is waiting for must not be handed to the next question."""
    check("the channel drops the replies nobody is waiting for", True)

    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "relay_under_test", os.path.join(os.path.dirname(__file__), "..", "beelink", "relay_mac.py"))
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        check("the relay can be loaded", False, str(exc)[:120])
        return

    channel = module.Channel()
    channel.responses.put(b"a reply from a question nobody is waiting for")
    dropped = channel.drain()
    check("the stale reply is dropped", dropped == 1, f"dropped={dropped}")
    check("nothing is left behind for the next question",
          channel.responses.empty())

    channel.responses.put(b"a real reply")
    check("a reply that is there is not dropped by mistake",
          channel.drain() == 1 and channel.responses.empty())


def main():
    bridge_port = free_port()
    tunnel_port = free_port()
    phone_port = free_port()

    print("RELAY TEST")
    print(f"  fake bridge on {bridge_port}, tunnel {tunnel_port}, phone {phone_port}")

    # a slow answer: 20 s, well past the 15 s timeout that used to break it
    bridge = FakeBridge(bridge_port, delay=20)
    bridge.start()

    relay = start("relay_mac.py", TOKEN, tunnel_port, phone_port)
    if not wait_for_port(phone_port):
        check("relay came up", False, "phone port never opened")
        stop(relay)
        bridge.stop()
        return 1
    check("relay came up", True)

    dialer = start("relay_dialer.py", "127.0.0.1", tunnel_port, TOKEN, bridge_port)
    time.sleep(2)

    # 1. a slow answer must arrive intact
    started = time.time()
    status, body = ask(phone_port)
    elapsed = time.time() - started
    check("a slow answer arrives intact", status == 200 and b"the slow answer" in body,
          f"status={status} body={body[:120]!r}")
    check("the answer was not cut short", elapsed >= 19,
          f"answered after only {elapsed:.1f}s - the timeout is still too short")

    # 2. a replaced dialer that then dies must not take the channel down
    second = start("relay_dialer.py", "127.0.0.1", tunnel_port, TOKEN, bridge_port)
    time.sleep(2)
    stop(dialer)
    time.sleep(2)

    status, body = ask(phone_port)
    check("the relay survives the old dialer dying", status == 200 and b"the slow answer" in body,
          f"status={status} body={body[:120]!r}")

    stop(second)
    stop(relay)
    bridge.stop()

    # 3. a Beelink that times out at first must not leave the phone with a 502
    flaky_port = free_port()
    flaky_tunnel = free_port()
    flaky_phone = free_port()
    flaky = FlakyBridge(flaky_port, fail_first=2)
    flaky.start()

    relay2 = start("relay_mac.py", TOKEN, flaky_tunnel, flaky_phone)
    if not wait_for_port(flaky_phone):
        check("the retry relay came up", False, "phone port never opened")
        stop(relay2)
        flaky.stop()
    else:
        check("the retry relay came up", True)
        dialer2 = start("relay_dialer.py", "127.0.0.1", flaky_tunnel, TOKEN, flaky_port)
        time.sleep(2)

        status, body = ask(flaky_phone)
        check("a timed-out answer is retried instead of returned as a 502",
              status == 200 and b"the slow answer" in body,
              f"status={status} body={body[:120]!r}")

        stop(dialer2)
        stop(relay2)
        flaky.stop()

    # A request whose client gave up leaves its reply behind. The phone's
    # health check gives up after six seconds and the bridge may well answer
    # it a minute later - and that reply was handed to the next question,
    # so the orb was read a health report instead of an answer.
    print()
    check_stale_replies()
    print()
    check_time_context()
    print()
    if FAILURES:
        print(f"RELAY TEST: {FAILURES} FAILURE(S)")
        return 1
    print("ALL RELAY TESTS PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
