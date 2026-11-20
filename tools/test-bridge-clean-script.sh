#!/usr/bin/env bash
#
# test-bridge-clean-script.sh - check BEELINK-BRIDGE-CLEAN.sh before it is
# sent to a machine we cannot reach.
#
# The script stops processes and starts a service, so it has to be right the
# first time. It runs against a fake home folder, a fake systemd and a fake
# bridge, and checks that:
#
#   * the service that restarts itself in a loop is stopped,
#   * every bridge process is stopped, including the whisper workers left
#     behind by the attempts that failed,
#   * the new bridge is put in place,
#   * exactly one bridge is left running,
#   * the health check passes and no secret is printed.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-$HERE/../BEELINK-BRIDGE-CLEAN.sh}"
if [ ! -f "$SCRIPT" ]; then
    echo "the script to test is not there: $SCRIPT" >&2
    exit 1
fi
WORK="$(mktemp -d)"
FAILURES=0
PIDS_TO_KILL=""

check() {
    if [ "$2" = "1" ]; then
        printf '  PASS  %s\n' "$1"
    else
        printf '  FAIL  %s  %s\n' "$1" "${3:-}"
        FAILURES=$((FAILURES + 1))
    fi
}

cleanup() {
    for PID in $PIDS_TO_KILL; do
        kill "$PID" 2>/dev/null
    done
    pkill -f "$WORK" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "BRIDGE CLEAN SANDBOX"

HOME_DIR="$WORK/home"
BIN="$WORK/bin"
STAGE_DIR="$WORK/stage"
mkdir -p "$HOME_DIR/orb-hermes" "$BIN" "$STAGE_DIR"

# ------------------------------------------------------- the fake bridge

cat > "$STAGE_DIR/hermes_bridge.py" <<'PY'
#!/usr/bin/env python3
"""A stand-in for the bridge."""
import time

BRIDGE_VERSION = "2026-11-19f"

while True:
    time.sleep(1)
PY
chmod +x "$STAGE_DIR/hermes_bridge.py"

# the bridge that is already running, and the whisper worker it left behind
cat > "$HOME_DIR/orb-hermes/hermes_bridge.py" <<'PY'
#!/usr/bin/env python3
import time
BRIDGE_VERSION = "2026-11-19c"
while True:
    time.sleep(1)
PY
chmod +x "$HOME_DIR/orb-hermes/hermes_bridge.py"

cat > "$HOME_DIR/orb-hermes/run-bridge.sh" <<'SH'
#!/usr/bin/env bash
export BRIDGE_TOKEN=test-token-123456
exec python3 "$HOME/orb-hermes/hermes_bridge.py"
SH
chmod +x "$HOME_DIR/orb-hermes/run-bridge.sh"

bash -c "exec -a 'python3 $HOME_DIR/orb-hermes/hermes_bridge.py' sleep 300" >/dev/null 2>&1 &
OLD_PID=$!
PIDS_TO_KILL="$PIDS_TO_KILL $OLD_PID"
bash -c "exec -a 'python3 $HOME_DIR/orb-hermes/hermes_bridge.py --whisper-worker' sleep 300" >/dev/null 2>&1 &
WORKER_PID=$!
PIDS_TO_KILL="$PIDS_TO_KILL $WORKER_PID"
sleep 1

# ------------------------------------------------------- the fake systemd

cat > "$BIN/systemctl" <<'SH'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SYSTEMCTL_LOG"
ALL="$*"
UNIT=""
for A in "$@"; do
    case "$A" in *.service) UNIT="$A" ;; esac
done
case "$UNIT" in
    orb-hermes.service)
        case "$ALL" in
            *is-enabled*) echo "enabled"; exit 0 ;;
            *is-active*) echo "inactive"; exit 3 ;;
            *status*) echo "orb-hermes.service - Orb Hermes bridge"; exit 0 ;;
        esac
        exit 0
        ;;
esac
exit 0
SH
chmod +x "$BIN/systemctl"

export SYSTEMCTL_LOG="$WORK/systemctl.log"
: > "$SYSTEMCTL_LOG"

# ----------------------------------------------- the fake stage + endpoints

python3 -m http.server 8899 --bind 127.0.0.1 --directory "$STAGE_DIR" >/dev/null 2>&1 &
STAGE_PID=$!
PIDS_TO_KILL="$PIDS_TO_KILL $STAGE_PID"
sleep 1

cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
URL=""; OUT=""; WANT_CODE=0; POST=0; BODY=""
PREV=""
for A in "$@"; do
    case "$PREV" in
        -o) OUT="$A" ;;
        -H) ;;
    esac
    [ "$A" = "-w" ] && WANT_CODE=1
    [ "$A" = "-X" ] && POST=1
    case "$A" in http*) URL="$A" ;; esac
    PREV="$A"
done
# a download of the bridge is passed through to the real stage server
case "$URL" in
    *8899/hermes_bridge.py) exec /usr/bin/curl "$@" ;;
esac
BODY='{"ok":true,"bridge":"2026-11-19f","hermes":"ollama","hermes_available":true,"stt":"whisper","tts":"unknown"}'
if [ -n "$OUT" ]; then printf '%s' "$BODY" > "$OUT"; else printf '%s' "$BODY"; fi
[ "$WANT_CODE" = "1" ] && printf '200'
exit 0
SH
chmod +x "$BIN/curl"

# ---------------------------------------------------------- run the script

echo "--- running the script"
OUT=$(PATH="$BIN:$PATH" HOME="$HOME_DIR" ORB_STAGE="http://127.0.0.1:8899" \
      bash "$SCRIPT" 2>&1)
echo "$OUT" | sed 's/^/    /' | head -60

# ------------------------------------------------------------- the checks

check "the service was stopped" \
    "$(grep -q -- "--user stop orb-hermes.service" "$SYSTEMCTL_LOG" && echo 1 || echo 0)" \
    "$(cat "$SYSTEMCTL_LOG" | tr '\n' ' ')"

check "the old bridge process is gone" \
    "$(kill -0 "$OLD_PID" 2>/dev/null && echo 0 || echo 1)"

check "the whisper worker is gone too" \
    "$(kill -0 "$WORKER_PID" 2>/dev/null && echo 0 || echo 1)"

check "the new bridge is in place" \
    "$(grep -q "2026-11-19f" "$HOME_DIR/orb-hermes/hermes_bridge.py" && echo 1 || echo 0)" \
    "$(grep -o "2026-11-19[a-z]" "$HOME_DIR/orb-hermes/hermes_bridge.py" | head -1)"

check "the old bridge was kept as a backup" \
    "$(ls "$HOME_DIR/orb-hermes/" | grep -q "bak-" && echo 1 || echo 0)"

check "the bridge was started again" \
    "$(pgrep -f "$HOME_DIR/orb-hermes/hermes_bridge.py" >/dev/null 2>&1 && echo 1 || echo 0)"

check "exactly one bridge is running" \
    "$(pgrep -f "$HOME_DIR/orb-hermes/hermes_bridge.py" 2>/dev/null | wc -l | tr -d ' ' | grep -q '^1$' && echo 1 || echo 0)" \
    "$(pgrep -af "$HOME_DIR/orb-hermes/hermes_bridge.py" 2>/dev/null | wc -l | tr -d ' ')"

check "the health check answered" \
    "$(echo "$OUT" | grep -q "the bridge answers: version" && echo 1 || echo 0)"

check "the token is never printed" \
    "$(echo "$OUT" | grep -q "test-token-123456" && echo 0 || echo 1)"

check "it says the bridge has one owner" \
    "$(echo "$OUT" | grep -qE "one process, run by one owner|started by hand" && echo 1 || echo 0)"

check "the service was tried before the hand start" \
    "$(grep -q -- "--user start orb-hermes.service" "$SYSTEMCTL_LOG" && echo 1 || echo 0)"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL BRIDGE CLEAN SCRIPT TESTS PASS"
    exit 0
fi
echo "BRIDGE CLEAN SCRIPT: $FAILURES FAILURE(S)"
exit 1
