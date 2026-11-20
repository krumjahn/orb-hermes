#!/usr/bin/env python3
"""
relay_mac.py - reverse byte-pipe relay for the Orb Hermes bridge.

The Beelink's firewall drops every inbound connection, but outbound works.
So the Beelink dials in here and keeps a channel open; the phone then talks to
a local port and the relay splices the two together.

    phone --http--> Mac:LOCAL_PORT --frames--> Beelink:8787

Protocol (between the relay and the dialer):

    dialer -> relay : b"TUNNEL <token>\\n"      handshake
    relay -> dialer : 4-byte length + payload   one client request
    dialer -> relay : 4-byte length + payload   one bridge response

The relay reads the client's HTTP request (headers + Content-Length body) so
it knows where one request ends, and frames it. The dialer opens a fresh
connection to the bridge for each request, because the bridge speaks HTTP/1.0
and closes after every response.

Usage:
    python3 relay_mac.py <TOKEN> [TUNNEL_PORT] [LOCAL_PORT]
"""
import datetime
import json
import socket
import socketserver
import struct
import sys
import threading
import time
import queue

TOKEN = sys.argv[1] if len(sys.argv) > 1 else "changeme"
TUNNEL_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8890
LOCAL_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8891

# A cold agent on the Beelink can take minutes: the CLI may try a broken
# mode first, then the quiet one, then fall back to Ollama. The relay must
# wait longer than all of that, or it gives up before the answer arrives.
RESPONSE_TIMEOUT = 420.0
# The keep-warm only has to keep the model loaded, so it waits far less - and
# it holds the channel while it does, so it must not block a real question.
KEEP_WARM_TIMEOUT = 60.0
MAX_REQUEST = 32 * 1024 * 1024

# How many times a request is put back through when the Beelink answers with
# its own 502, and how long to wait first. The 502 comes from the dialer on
# the Beelink giving up on the bridge, which usually means the model was cold
# and had not finished loading yet. A cold 27B model needs the better part of
# a minute to load, so there is room for a few attempts here - the phone
# waits 180 s for an answer, and eight attempts fit inside that.
RETRIES = 8
RETRY_DELAY = 2.0

# The Beelink's Ollama drops the model from memory when it has been idle for
# a while, and loading it again takes longer than the dialer's read window.
# The first question after a quiet spell would then always come back as a
# 502. A tiny request every few minutes keeps the model where it is, so the
# first real question is answered straight away.
KEEP_WARM_INTERVAL = 150.0
KEEP_WARM_IDLE = 120.0
KEEP_WARM_STARTUP = 20.0


def is_gateway_error(response: bytes) -> bool:
    """Is this the 502 the Beelink's dialer makes when its read window runs out?"""
    return response.startswith(b"HTTP/1.0 502") or response.startswith(b"HTTP/1.1 502")


def response_body(response: bytes) -> str:
    """The body of a small text response, for the log. Empty for audio."""
    head, _, body = response.partition(b"\r\n\r\n")
    if b"audio" in head.lower() or len(body) > 400:
        return ""
    return body.decode(errors="replace").strip()


# The model has no clock. Without this it answers "what time is it" with
# "I don't have access to the current time". The line is added to the
# question before it goes to the Beelink, and the marker keeps it from being
# added twice.
TIME_MARKER = "[current local time"
TIME_PREFIX = "[current local time: {stamp}]\n\n"

WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


def _date_in(stamp: str):
    """The YYYY-MM-DD date inside a timestamp, if there is one."""
    for index in range(len(stamp) - 9):
        chunk = stamp[index:index + 10]
        if chunk[4] == "-" and chunk[7] == "-":
            try:
                return datetime.date(int(chunk[0:4]), int(chunk[5:7]), int(chunk[8:10]))
            except ValueError:
                return None
    return None


def with_weekday(stamp: str) -> str:
    """Name the weekday, so the model never has to work it out itself.

    Given only a date, the model called November 17 a Monday, so the weekday
    is worked out here and handed over ready-made.
    """
    if any(stamp.startswith(day) for day in WEEKDAYS):
        return stamp
    day = _date_in(stamp)
    if day is None:
        return stamp
    return f"{WEEKDAYS[day.weekday()]}, {stamp}"


def local_time_line(now=None, zone=None) -> str:
    """One line telling the model what time it is where the user is."""
    if now:
        stamp = with_weekday(str(now))
        if zone:
            stamp = f"{stamp} ({zone})"
    else:
        stamp = time.strftime("%A, %Y-%m-%d %H:%M:%S %Z")
    return TIME_PREFIX.format(stamp=stamp)


def inject_time_context(request: bytes, request_line: str) -> bytes:
    """Add the current time to an interactive chat request.

    Only conversations are given the time. A one-shot request without a
    session is a background job - the meeting-notes daemon asks for notes
    from a transcript, and a date in the prompt would only make the model
    mention dates that were never said.
    """
    if "/chat" not in request_line:
        return request
    head, sep, body = request.partition(b"\r\n\r\n")
    if not sep:
        return request
    try:
        payload = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return request
    if not isinstance(payload, dict):
        return request

    text = str(payload.get("text", ""))
    if not text or text.startswith(TIME_MARKER):
        return request
    if "session" not in payload and "now" not in payload:
        return request

    payload["text"] = local_time_line(payload.get("now"), payload.get("timezone")) + text
    new_body = json.dumps(payload).encode("utf-8")

    lines = []
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            lines.append(f"Content-Length: {len(new_body)}".encode())
        else:
            lines.append(line)
    return b"\r\n".join(lines) + sep + new_body


def log(*args):
    print("[relay]", *args, flush=True)


def request_preview(request: bytes, limit: int = 300) -> str:
    """The first bit of a request body, for the log."""
    _, sep, body = request.partition(b"\r\n\r\n")
    if not sep:
        return ""
    text = body.decode("utf-8", "replace").replace("\n", " ").strip()
    if len(text) > limit:
        text = text[:limit] + "..."
    return text


def send_frame(sock, payload):
    sock.sendall(struct.pack("!I", len(payload)) + payload)


def recv_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def recv_frame(sock):
    header = recv_exact(sock, 4)
    if header is None:
        return None
    (length,) = struct.unpack("!I", header)
    if length > MAX_REQUEST:
        raise ValueError(f"frame too large: {length}")
    return recv_exact(sock, length)


def read_http_request(sock):
    """Read one HTTP request from a client.

    Returns (raw bytes, request line) - the request line is kept so the log
    says which endpoint was used, not just how big it was.
    """
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            return None, ""
        buf += chunk
        if len(buf) > MAX_REQUEST:
            return None, ""
    head, rest = buf.split(b"\r\n\r\n", 1)
    length = 0
    for line in head.split(b"\r\n")[1:]:
        key, _, value = line.partition(b":")
        if key.strip().lower() == b"content-length":
            try:
                length = int(value.strip())
            except ValueError:
                length = 0
    while len(rest) < length:
        chunk = sock.recv(65536)
        if not chunk:
            break
        rest += chunk
    request_line = head.split(b"\r\n", 1)[0].decode(errors="replace")
    return head + b"\r\n\r\n" + rest, request_line


class Channel:
    """The live connection to the Beelink, plus the replies it sends back."""

    def __init__(self):
        self.lock = threading.Lock()
        self.sock = None
        self.responses = queue.Queue()
        self.alive = False
        self.last_request_at = 0.0
        self.last_model_at = 0.0
        self.last_client_at = 0.0
        # One request at a time. The dialer answers in order, so sending a
        # request and taking its reply have to be one indivisible step -
        # otherwise the keep-warm could pick up the phone's reply, or the
        # other way round.
        self.exchange = threading.Lock()

    def attach(self, sock):
        with self.lock:
            self.sock = sock
            self.alive = True
        # a reply from the previous dialer would be answered to the wrong
        # request, so the queue starts empty for the new one
        while True:
            try:
                self.responses.get_nowait()
            except queue.Empty:
                break

    def detach(self, sock=None):
        """Drop the connection, but only if it is still the live one.

        A dialer that reconnects replaces the channel. When the *old* dialer
        finally goes away its handler still runs, and without this guard it
        would clear the channel that the new dialer had already taken over -
        leaving the relay attached to a socket nobody uses, with the live
        dialer waiting for a request that never comes.
        """
        with self.lock:
            if sock is not None and self.sock is not sock:
                return
            self.sock = None
            self.alive = False

    def send_request(self, payload):
        with self.lock:
            if self.sock is None:
                raise OSError("no dialer connected")
            send_frame(self.sock, payload)
            self.last_request_at = time.time()

    def mark_model_used(self):
        """Note that the model was asked to work, so it stays loaded."""
        with self.lock:
            self.last_model_at = time.time()

    def mark_client_request(self):
        """Note that the phone is talking, so the keep-warm keeps away."""
        with self.lock:
            self.last_client_at = time.time()

    def seconds_since_model_use(self):
        with self.lock:
            if self.last_model_at == 0.0:
                return float("inf")
            return time.time() - self.last_model_at

    def seconds_since_client_request(self):
        with self.lock:
            if self.last_client_at == 0.0:
                return float("inf")
            return time.time() - self.last_client_at

    def take_response(self, timeout):
        return self.responses.get(timeout=timeout)

    def drain(self):
        """Throw away the replies that nobody is waiting for any more.

        One request at a time goes through the channel, so a reply that is
        still lying in the queue belongs to a request whose client had
        already given up - the phone's health check gives up after six
        seconds, and the bridge may well answer it a minute later. Handing
        that reply to the next question meant the orb was read a health
        report instead of an answer.
        """
        dropped = 0
        while True:
            try:
                self.responses.get_nowait()
                dropped += 1
            except queue.Empty:
                if dropped:
                    log(f"dropped {dropped} stale replie(s)")
                return dropped


CHANNEL = Channel()


class DialerHandler(socketserver.BaseRequestHandler):
    """The Beelink side of the relay."""

    def handle(self):
        sock = self.request
        sock.settimeout(30)
        try:
            handshake = sock.recv(256)
        except OSError:
            return
        if not handshake.startswith(b"TUNNEL "):
            log("dialer sent a bad handshake, ignoring")
            return
        if handshake.split(None, 1)[1].strip().decode(errors="replace") != TOKEN:
            log("dialer presented the wrong token, ignoring")
            return
        sock.settimeout(None)
        log("Beelink dialled in")
        CHANNEL.attach(sock)
        try:
            while True:
                payload = recv_frame(sock)
                if payload is None:
                    break
                CHANNEL.responses.put(payload)
        except (OSError, ValueError):
            pass
        finally:
            log("Beelink disconnected")
            CHANNEL.detach(sock)


class LocalHandler(socketserver.BaseRequestHandler):
    """The phone side of the relay."""

    def handle(self):
        sock = self.request
        sock.settimeout(RESPONSE_TIMEOUT)
        peer = sock.getpeername()
        try:
            request, request_line = read_http_request(sock)
            if not request:
                log(f"client {peer} sent no request")
                return
            log(f"client {peer} -> {len(request)} bytes {request_line}")
            # the question and the voice are worth seeing: the answer can only
            # be checked against what was actually asked
            if "/chat" in request_line or "/tts" in request_line:
                preview = request_preview(request)
                if preview:
                    log(f"client {peer} asks: {preview}")
            CHANNEL.mark_client_request()

            # The model has no clock of its own, so the time goes with the
            # question.
            request = inject_time_context(request, request_line)

            response = None
            for attempt in range(1, RETRIES + 1):
                with CHANNEL.exchange:
                    if "/chat" in request_line:
                        CHANNEL.mark_model_used()
                    CHANNEL.drain()
                    CHANNEL.send_request(request)
                    response = CHANNEL.take_response(RESPONSE_TIMEOUT)
                if response is None:
                    log(f"client {peer}: no reply from the Beelink in time")
                    return
                if is_gateway_error(response) and attempt < RETRIES:
                    # The Beelink's dialer gives up on the bridge after its own
                    # read window and answers with a 502 of its own. That
                    # usually means the model was cold and is loading right
                    # now, so the same request a moment later gets a real
                    # answer.
                    log(
                        f"client {peer}: the Beelink timed out, retrying "
                        f"({attempt}/{RETRIES})"
                    )
                    time.sleep(RETRY_DELAY)
                    continue
                break

            sock.sendall(response)
            status = response.split(b"\r\n", 1)[0].decode(errors="replace")
            log(f"client {peer} <- {len(response)} bytes {status}")
            body = response_body(response)
            if body:
                log(f"client {peer} says: {body}")
        except OSError as exc:
            log(f"client {peer} failed: {exc}")
        finally:
            try:
                sock.close()
            except OSError:
                pass


class ThreadedTCPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def keep_warm_loop():
    """Keep the model on the Beelink loaded so the first question is quick."""
    body = b'{"text":"ping"}'
    request = (
        b"POST /chat HTTP/1.1\r\n"
        b"Host: keep-warm\r\n"
        b"Content-Type: application/json\r\n"
        + f"Content-Length: {len(body)}\r\n".encode()
        + (f"X-Auth-Token: {TOKEN}\r\n".encode() if TOKEN else b"")
        + b"\r\n"
        + body
    )
    waited = KEEP_WARM_STARTUP
    while True:
        time.sleep(waited)
        waited = KEEP_WARM_INTERVAL
        # If the model was asked to work recently it is still loaded, and
        # there is no reason to disturb it.
        if CHANNEL.seconds_since_model_use() < KEEP_WARM_IDLE:
            continue
        # One attempt only. A keep-warm that keeps retrying just queues more
        # work behind whatever the Beelink is already doing.
        for attempt in range(1, 2):
            # The phone comes first: if it is talking, leave the Beelink to it.
            if CHANNEL.seconds_since_client_request() < 10:
                break
            try:
                with CHANNEL.exchange:
                    CHANNEL.drain()
                    CHANNEL.send_request(request)
                    response = CHANNEL.take_response(KEEP_WARM_TIMEOUT)
            except OSError as exc:
                log(f"keep-warm: {exc}")
                break
            except Exception as exc:  # noqa: BLE001
                log(f"keep-warm: {exc}")
                break
            if response is None:
                log("keep-warm: no reply from the Beelink")
                break
            if not is_gateway_error(response):
                log("keep-warm: the model is warm")
                break
            # The model is still loading. The load carries on on the Beelink
            # even though this request was cut off, so the next one finds it.
            log(f"keep-warm: still loading, retrying ({attempt}/{RETRIES})")
            time.sleep(RETRY_DELAY)


def main():
    dialer = ThreadedTCPServer(("0.0.0.0", TUNNEL_PORT), DialerHandler)
    threading.Thread(target=dialer.serve_forever, daemon=True).start()

    threading.Thread(target=keep_warm_loop, daemon=True).start()

    local = ThreadedTCPServer(("0.0.0.0", LOCAL_PORT), LocalHandler)
    log(f"Beelink dials http://<this-ip>:{TUNNEL_PORT}/tunnel")
    log(f"the phone uses   http://<this-ip>:{LOCAL_PORT}")
    log("ready")
    local.serve_forever()


if __name__ == "__main__":
    main()
