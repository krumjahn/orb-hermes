#!/usr/bin/env python3
"""
test-bridge-wake.py - check the bridge's wake-word matcher.

The bridge and the phone run the same matching rules, because either one may
be the one that spots the wake word. This checks the bridge's copy against
the same cases the Kotlin test suite uses, so the two cannot drift apart.

It only loads the matcher functions - the server is never started.
"""
import os
import re
import sys
import json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "beelink", "hermes_bridge.py")
RELAY = os.path.join(ROOT, "beelink", "relay_mac.py")

CASES = [
    ("Orbit", True),
    ("orbit", True),
    ("orbits", True),
    ("or bit", True),
    ("or a bit", True),
    ("or a bit.", True),
    ("or u bit", True),
    ("hey orbit", True),
    ("Orbit, what time is it", True),
    ("orbt", True),
    ("orbit of mars", True),
    # whisper renders the word with a swallowed "t" every now and then
    ("or bid", True),
    ("or bids", True),
    ("or b it", True),
    # and sometimes mis-hears the whole word: an aspirated h, a final d
    ("Horbid, what do you know about me?", True),
    ("Horbit what time is it", True),
    ("orbot what time is it", True),
    # the wake word clipped down to "orb" - it keeps its consonants
    ("orb", True),
    ("hey orb", True),
    # a bare "or" is only the wake word when it is all the transcriber heard:
    # "or" on its own is an ordinary English word, and treating it as the
    # wake word woke the orb on nearly every sentence that started with one
    ("or", True),
    ("hey or", True),
    ("or what time is it", False),
    ("hey or what time is it", False),
    ("Or, but what time is it?", True),
    # a joined run of words has to sound like the word, not merely be a
    # couple of edits away from it: "or not" is "ornot", and that is what a
    # television said while the orb was listening
    ("or not", False),
    ("or not at all", False),
    ("or maybe", False),
    ("or something", False),
    ("or the", False),
    ("or just", False),
    ("or buy", False),
    ("or ant", False),
    ("or wet", False),
    ("longer, they gained about an extra hour or not.", False),
    # words that merely look or sound similar must not wake the orb
    ("a rabbit", False),
    ("herb", False),
    ("my habit is reading", False),
    ("hello there", False),
    ("for a bit", False),
    ("work on it", False),
    ("can you order a pizza", False),
    ("tell me a story", False),
    ("", False),
    (".", False),
]


def load_matcher():
    src = open(BRIDGE, encoding="utf-8").read()
    start = src.index("def _wake_aliases")
    end = src.index("def wake_detected")
    tail = src[end:]
    stop = tail.index("\n\n\n") + end if "\n\n\n" in tail else len(src)
    namespace = {"re": re, "os": os}
    exec(src[start:stop], namespace)  # noqa: S102 - the bridge's own source
    return namespace["wake_detected"]


def load_relay():
    """The relay's own copy of the matcher, and its gate."""
    src = open(RELAY, encoding="utf-8").read()
    start = src.index("WAKE_PHRASE = ")
    stop = src.index("# The model has no clock", start)
    namespace = {"re": re, "json": json}
    exec(src[start:stop], namespace)  # noqa: S102 - the relay's own source
    return namespace["wake_detected"], namespace["gate_wake_response"]


def check_cases(label, wake_detected):
    failures = 0
    print(label)
    for text, want in CASES:
        got = wake_detected(text)
        ok = got == want
        if not ok:
            failures += 1
        print(f"  {'PASS' if ok else 'FAIL'}  {text!r:32} -> {got} (want {want})")
    print()
    return failures


def check_gate(gate_wake_response):
    """The relay's second opinion on the bridge's wake word."""
    failures = 0
    print("RELAY WAKE GATE")
    cases = [
        # a real wake word is passed through untouched
        (b'{"text": "Orbit, what time is it", "wake": true}',
         b"POST /wake HTTP/1.1", True),
        # a false wake is turned off, and the transcript is left alone
        (b'{"text": "or not", "wake": true}',
         b"POST /wake HTTP/1.1", False),
        (b'{"text": "longer, they gained about an extra hour or not.", "wake": true}',
         b"POST /wake HTTP/1.1", False),
        # a wake that is already off is left alone
        (b'{"text": "or not", "wake": false}',
         b"POST /wake HTTP/1.1", False),
    ]
    for body, line, want_wake in cases:
        head = (b"HTTP/1.0 200 OK\r\nContent-Type: application/json\r\n"
                b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
        out = gate_wake_response(head, line.decode())
        text = out.partition(b"\r\n\r\n")[2].decode()
        got = json.loads(text)
        ok = got.get("wake") == want_wake
        if not ok:
            failures += 1
        # the transcript must survive untouched
        if json.loads(text).get("text") != json.loads(body).get("text"):
            failures += 1
            ok = False
        # the length in the header has to match the new body
        length = int(out.partition(b"\r\n\r\n")[0].split(b"Content-Length:")[1]
                     .split(b"\r\n")[0])
        if length != len(out.partition(b"\r\n\r\n")[2]):
            failures += 1
            ok = False
        print(f"  {'PASS' if ok else 'FAIL'}  {body!r:56} -> wake={got.get('wake')}")
    print()
    return failures


def main():
    failures = 0
    failures += check_cases("BRIDGE WAKE MATCHER", load_matcher())
    relay_wake, relay_gate = load_relay()
    failures += check_cases("RELAY WAKE MATCHER", relay_wake)
    failures += check_gate(relay_gate)

    if failures:
        print(f"WAKE MATCHER: {failures} FAILURES")
        return 1
    print(f"ALL WAKE MATCHER TESTS PASS ({len(CASES) * 2 + 4} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
