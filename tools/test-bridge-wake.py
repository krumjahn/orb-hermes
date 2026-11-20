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

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "beelink", "hermes_bridge.py")

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
    # the wake word clipped down to "or" - only at the front of a phrase
    ("or what time is it", True),
    ("Or, but what time is it?", True),
    ("hey or what time is it", True),
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


def main():
    wake_detected = load_matcher()
    failures = 0
    print("BRIDGE WAKE MATCHER")
    for text, want in CASES:
        got = wake_detected(text)
        ok = got == want
        if not ok:
            failures += 1
        print(f"  {'PASS' if ok else 'FAIL'}  {text!r:32} -> {got} (want {want})")
    print()
    if failures:
        print(f"BRIDGE WAKE MATCHER: {failures} FAILURES")
        return 1
    print(f"ALL BRIDGE WAKE MATCHER TESTS PASS ({len(CASES)} checks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
