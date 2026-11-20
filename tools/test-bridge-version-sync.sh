#!/usr/bin/env bash
#
# test-bridge-version-sync.sh - keep the install scripts and the bridge on
# the same version.
#
# Every script that puts the bridge in place checks the version it downloads
# against a constant. When the bridge is rebuilt and the constants are not
# bumped, the script refuses a perfectly good download - and the orb is left
# on the old build without anyone noticing. This test catches that before the
# script is sent to the Beelink.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"
BRIDGE="${ORB_BRIDGE:-$PROJECT/beelink/hermes_bridge.py}"
STAGE="${ORB_STAGE_DIR:-$HOME/.orb-hermes/stage}"
FAILURES=0

check() {
    if [ "$2" = "1" ]; then
        printf '  PASS  %s\n' "$1"
    else
        printf '  FAIL  %s  %s\n' "$1" "${3:-}"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "BRIDGE VERSION SYNC"

if [ ! -f "$BRIDGE" ]; then
    echo "  FAIL  the bridge is not there: $BRIDGE"
    exit 1
fi

BRIDGE_VERSION=$(grep -m1 'BRIDGE_VERSION[[:space:]]*=' "$BRIDGE" 2>/dev/null \
    | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[a-z]?' | head -1)
echo "    the bridge is version $BRIDGE_VERSION"

check "the bridge has a version" \
    "$([ -n "$BRIDGE_VERSION" ] && echo 1 || echo 0)"

# every script that installs the bridge has to expect that same version
for SCRIPT in "$PROJECT/BEELINK-BRIDGE-UPDATE.sh" "$PROJECT/BEELINK-BRIDGE-CLEAN.sh" \
               "$PROJECT/BEELINK-AGENT-VERIFY.sh"; do
    NAME=$(basename "$SCRIPT")
    if [ ! -f "$SCRIPT" ]; then
        check "$NAME is there" 0 "$SCRIPT"
        continue
    fi
    EXPECTED=$(sed -nE 's/^EXPECTED_VERSION="([^"]+)".*/\1/p' "$SCRIPT" | head -1)
    check "$NAME expects $BRIDGE_VERSION" \
        "$([ "$EXPECTED" = "$BRIDGE_VERSION" ] && echo 1 || echo 0)" \
        "it expects ${EXPECTED:-none}"
done

# and the staged copy - the one the Beelink downloads - has to be the same
if [ -f "$STAGE/hermes_bridge.py" ]; then
    STAGED_VERSION=$(grep -m1 'BRIDGE_VERSION[[:space:]]*=' "$STAGE/hermes_bridge.py" 2>/dev/null \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[a-z]?' | head -1)
    check "the staged bridge is $BRIDGE_VERSION" \
        "$([ "$STAGED_VERSION" = "$BRIDGE_VERSION" ] && echo 1 || echo 0)" \
        "the stage has ${STAGED_VERSION:-none}"
else
    check "the staged bridge is there" 0 "$STAGE/hermes_bridge.py"
fi

# the scripts that go to the Beelink have to parse before they are sent
for SCRIPT in "$PROJECT/BEELINK-BRIDGE-UPDATE.sh" "$PROJECT/BEELINK-BRIDGE-CLEAN.sh" \
               "$PROJECT/BEELINK-AGENT-VERIFY.sh"; do
    NAME=$(basename "$SCRIPT")
    check "$NAME parses" \
        "$(bash -n "$SCRIPT" 2>/dev/null && echo 1 || echo 0)"
done

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL BRIDGE VERSION SYNC TESTS PASS"
    exit 0
fi
echo "BRIDGE VERSION SYNC: $FAILURES FAILURE(S)"
exit 1
