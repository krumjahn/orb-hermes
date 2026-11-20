#!/usr/bin/env python3
"""
relay_dialer.py - run this ON the Beelink.

The Beelink's firewall drops every inbound connection, but outbound works.
So the Beelink dials out to the Mac's relay and splices the local bridge
through it:

    MAC:8890  --frames-->  dialer  --http-->  127.0.0.1:8787

Protocol (between the dialer and the relay):

    dialer -> relay : b"TUNNEL <token>\\n"      handshake
    relay -> dialer : 4-byte length + payload   one client request
    dialer -> relay : 4-byte length + payload   one bridge response

The bridge speaks HTTP/1.0 and closes the connection after every response, so
a fresh connection to it is opened for each request.

Usage:
    python3 relay_dialer.py <MAC_IP> <TUNNEL_PORT> <TOKEN> [BRIDGE_PORT]
"""
import socket
import struct
import sys
import time

MAC = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.10"
TUNNEL_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8890
TOKEN = sys.argv[3] if len(sys.argv) > 3 else "changeme"
BRIDGE_PORT = int(sys.argv[4]) if len(sys.argv) > 4 else 8787

RETRY_DELAY = 0.5
# How long to wait for the bridge to answer. A cold agent on this machine can
# take minutes - the CLI may try a broken mode first, then the quiet one,
# then fall back to Ollama - so the dialer has to wait longer than all of
# that, or it gives up before the answer arrives.
BRIDGE_TIMEOUT = 420.0


def log(*args):
    print("[dialer]", *args, flush=True)


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
    return recv_exact(sock, length)


def ask_bridge(request):
    """Send one request to the local bridge and return its whole response."""
    # The connect timeout stays short, but the *read* timeout has to be
    # generous: a 27B model on this machine can take 10-16 s to answer, and
    # the 15 s socket timeout that came with create_connection() was cutting
    # the reply off. The phone itself waits 180 s for a chat.
    bridge = socket.create_connection(("127.0.0.1", BRIDGE_PORT), timeout=15)
    bridge.settimeout(BRIDGE_TIMEOUT)
    try:
        bridge.sendall(request)
        chunks = []
        while True:
            data = bridge.recv(65536)
            if not data:
                break
            chunks.append(data)
        return b"".join(chunks)
    finally:
        try:
            bridge.close()
        except OSError:
            pass


def run_once():
    upstream = socket.create_connection((MAC, TUNNEL_PORT), timeout=15)
    try:
        upstream.sendall(f"TUNNEL {TOKEN}\n".encode())
        upstream.settimeout(None)
        log(f"connected to {MAC}:{TUNNEL_PORT}")
        while True:
            request = recv_frame(upstream)
            if request is None:
                break
            try:
                response = ask_bridge(request)
            except OSError as exc:
                log(f"bridge unreachable: {exc}")
                response = b"HTTP/1.0 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
            send_frame(upstream, response)
    finally:
        try:
            upstream.close()
        except OSError:
            pass


def main():
    log(f"splicing 127.0.0.1:{BRIDGE_PORT} through {MAC}:{TUNNEL_PORT}")
    while True:
        try:
            run_once()
        except Exception as exc:  # noqa: BLE001 - the link must never die for good
            log(f"link dropped: {type(exc).__name__}: {exc}")
        time.sleep(RETRY_DELAY)


if __name__ == "__main__":
    main()
