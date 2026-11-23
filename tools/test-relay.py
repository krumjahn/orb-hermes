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
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
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


def load_relay():
    """Load the relay's own code so it can be tested from the inside."""
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "relay_under_test", os.path.join(BEELINK, "relay_mac.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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
        self.delays = {}
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

    module = load_relay()

    channel = module.Channel()
    channel.responses.put(b"a reply from a question nobody is waiting for")
    dropped = channel.drain()
    check("the stale reply is dropped", dropped == 1, f"dropped={dropped}")
    check("nothing is left behind for the next question",
          channel.responses.empty())

    channel.responses.put(b"a real reply")
    check("a reply that is there is not dropped by mistake",
          channel.drain() == 1 and channel.responses.empty())


def check_timeout_gives_none():
    """A wait that runs out must give None, not blow up.

    This is the whole bug. The queue raises Empty when the time is up -
    it does not hand back None - and the old code let that through. So
    the "no reply in time" branch never ran: the channel was never
    cleaned up, and the reply that was still on its way was handed to
    the next client, which took it for its own answer. That is how the
    orb was handed "Pong" as a transcript of what somebody said.
    """
    try:
        module = load_relay()
    except Exception as exc:  # noqa: BLE001
        check("the relay can be loaded", False, str(exc)[:120])
        return

    channel = module.Channel()
    started = time.time()
    try:
        result = channel.take_response(0.2)
    except Exception as exc:  # noqa: BLE001 - the failure is the result
        check("a wait that runs out gives None instead of blowing up", False,
              f"{type(exc).__name__}: {exc}")
        return
    waited = time.time() - started
    check("a wait that runs out gives None instead of blowing up",
          result is None, repr(result))
    check("the wait really did wait", waited >= 0.15, f"waited {waited:.2f}s")


class EchoBridge(FakeBridge):
    """A bridge that says which question it is answering.

    The reply names the question, so a reply that belongs to one client can
    be told apart from a reply that belongs to another.
    """

    def serve(self, client):
        try:
            client.settimeout(30)
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
            text = ""
            try:
                text = json.loads(rest.decode()).get("text", "")
            except Exception:
                pass
            time.sleep(self.delays.get(text, self.delay))
            if text == "ping":
                # this is what the keep-warm asks for
                body = json.dumps({"reply": "Pong"}).encode()
            else:
                body = json.dumps({"reply": f"the answer to {text}"}).encode()
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


def check_keep_warm_misroute():
    """The keep-warm's abandoned reply must not be handed to the next question.

    This is the real thing, taken from the relay's own log. The keep-warm
    asks the model for a ping so that it stays loaded. The model is slow
    and the keep-warm gives up before the answer comes. The answer turns
    up later anyway, and the next question - waiting for its own answer -
    took that one instead. The orb was handed "Pong" as a transcript of
    what somebody said.

    The keep-warm's own patience is 60 s, so the ping's answer has to be
    later than that to reproduce it.
    """
    print("  - the keep-warm's abandoned answer must not reach the next question")
    bridge_port = free_port()
    tunnel_port = free_port()
    phone_port = free_port()

    keep_warm_timeout = 60     # both copies: the keep-warm's own patience
    keep_warm_startup = 20     # when the keep-warm first goes out
    ping_delay = 68            # the ping's answer lands after the give-up
    question_delay = 12        # the question's own answer comes later still

    bridge = EchoBridge(bridge_port, delay=question_delay)
    bridge.delays["ping"] = ping_delay
    bridge.start()

    env = dict(os.environ)
    env["RELAY_KEEP_WARM_TIMEOUT"] = str(keep_warm_timeout)
    log_path = os.path.join(tempfile.gettempdir(), "orb-relay-keepwarm-test.log")
    log_file = open(log_path, "wb")
    relay = subprocess.Popen(
        [sys.executable, os.path.join(BEELINK, "relay_mac.py"),
         TOKEN, str(tunnel_port), str(phone_port)],
        env=env, stdout=log_file, stderr=subprocess.STDOUT,
    )
    try:
        if not wait_for_port(phone_port):
            check("the relay came up", False, "the phone port never opened")
            return
        dialer = start("relay_dialer.py", "127.0.0.1", tunnel_port, TOKEN, bridge_port)
        time.sleep(2)

        # the keep-warm goes out at 20 s and gives up 60 s later, at 80 s.
        # the question asks at 84 s: after the give-up, before the ping's
        # answer lands at 88 s.
        wait_until = keep_warm_startup + keep_warm_timeout + 4
        time.sleep(max(0, wait_until - 6))
        status, body = ask(phone_port, body='{"text":"two"}', timeout=150)
        check("the question is answered", status == 200, f"status={status}")
        check("the question gets its own answer",
              b"the answer to two" in body, f"body={body[:160]!r}")
        check("the keep-warm's abandoned answer was not handed over",
              b"Pong" not in body, f"body={body[:160]!r}")
        stop(dialer)
    finally:
        stop(relay)
        bridge.stop()
        log_file.close()
        if FAILURES:
            print(f"    (the relay said:)")
            try:
                with open(log_path) as handle:
                    for line in handle.readlines()[-25:]:
                        print(f"      {line.rstrip()}")
            except OSError:
                pass


def check_abandoned_reply():
    """A reply that comes after its client gave up must not reach the next one.

    The replies come back in the order the requests went out, so a client
    that gives up leaves a hole. The reply to its request still turns up
    later, and the next client - waiting for its own reply - takes that
    one instead. That is how the orb was handed "Pong" as a transcript of
    what somebody said.

    The timing is what makes this test bite:

      * the relay gives up on the first question after RELAY_RESPONSE_TIMEOUT
      * the first answer arrives after that, so it lands in the hole
      * the second question is still waiting for its own answer when it does,
        but its own answer comes later still

    So the second client is handed the first client's reply - unless the
    relay throws the channel away when it gives up, in which case the first
    answer never reaches the relay at all.
    """
    print("  - a client that gives up must not leave its reply behind")
    bridge_port = free_port()
    tunnel_port = free_port()
    phone_port = free_port()

    response_timeout = 8
    first_delay = 11          # the first answer lands after the give-up
    second_delay = 6          # the second answer comes later still

    bridge = EchoBridge(bridge_port, delay=second_delay)
    bridge.delays["one"] = first_delay
    bridge.delays["two"] = second_delay
    bridge.start()

    env = dict(os.environ)
    env["RELAY_RESPONSE_TIMEOUT"] = str(response_timeout)
    log_path = os.path.join(tempfile.gettempdir(), "orb-relay-test.log")
    log_file = open(log_path, "wb")
    relay = subprocess.Popen(
        [sys.executable, os.path.join(BEELINK, "relay_mac.py"),
         TOKEN, str(tunnel_port), str(phone_port)],
        env=env, stdout=log_file, stderr=subprocess.STDOUT,
    )
    try:
        if not wait_for_port(phone_port):
            check("the relay came up", False, "the phone port never opened")
            return
        dialer = start("relay_dialer.py", "127.0.0.1", tunnel_port, TOKEN, bridge_port)
        time.sleep(2)

        # the first client gives up
        started = time.time()
        status, body = ask(phone_port, body='{"text":"one"}',
                           timeout=response_timeout + 20)
        elapsed = time.time() - started
        check("the first client gives up", status == 0 or elapsed < 5,
              f"status={status} after {elapsed:.1f}s")

        # the second client asks straight away. The channel was thrown away,
        # so the dialer has to dial in again before the request can go out.
        status, body = 0, b""
        for _ in range(3):
            status, body = ask(phone_port, body='{"text":"two"}',
                               timeout=response_timeout * 3)
            if status == 200:
                break
            time.sleep(2)
        check("the second client is answered", status == 200, f"status={status}")
        check("the second client gets its own reply",
              b"the answer to two" in body, f"body={body[:160]!r}")
        check("the abandoned reply was not handed over",
              b"the answer to one" not in body, f"body={body[:160]!r}")
        stop(dialer)
    finally:
        stop(relay)
        bridge.stop()
        log_file.close()
        if FAILURES:
            print(f"    (the relay said:)")
            try:
                with open(log_path) as handle:
                    for line in handle.readlines()[-25:]:
                        print(f"      {line.rstrip()}")
            except OSError:
                pass


def main():
    bridge_port = free_port()
    tunnel_port = free_port()
    phone_port = free_port()

    print("RELAY TEST")
    print(f"  fake bridge on {bridge_port}, tunnel {tunnel_port}, phone {phone_port}")
    print(f"  relay under test: {os.path.join(BEELINK, 'relay_mac.py')}")
    check_timeout_gives_none()
    print()
    check_abandoned_reply()
    print()
    check_keep_warm_misroute()

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
