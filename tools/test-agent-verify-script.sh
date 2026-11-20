#!/usr/bin/env bash
#
# test-agent-verify-script.sh - check BEELINK-AGENT-VERIFY.sh before it is
# sent to a machine we cannot reach.
#
# The script stops processes, installs the bridge and asks the agent a real
# question, so it has to be right the first time. It runs against a fake home
# folder, a fake systemd, a fake stage server and a fake bridge, and checks
# that:
#
#   * the current bridge is installed and the old one is kept,
#   * the model the agent uses is shown, and where that name came from,
#   * the question really reaches the agent,
#   * the report says which backend answered,
#   * no secret is ever printed.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-$HERE/../BEELINK-AGENT-VERIFY.sh}"
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

echo "AGENT VERIFY SANDBOX"

HOME_DIR="$WORK/home"
BIN="$WORK/bin"
STAGE_DIR="$WORK/stage"
mkdir -p "$HOME_DIR/orb-hermes" "$HOME_DIR/.hermes" "$BIN" "$STAGE_DIR"

# ------------------------------------------------------- the fake settings

cat > "$HOME_DIR/.hermes/config.yaml" <<'YAML'
model:
  default: qwen3.8-27b-hermes
  provider: custom
  base_url: http://localhost:11434/v1
stt:
  model: base
api_key: should-never-be-printed
YAML

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
PIDS_TO_KILL="$PIDS_TO_KILL $!"
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
PIDS_TO_KILL="$PIDS_TO_KILL $!"
sleep 1

export CHAT_LOG="$WORK/chat.log"
: > "$CHAT_LOG"

cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
URL=""; OUT=""; WANT_CODE=0; POST=0; BODY=""; NEXT=""
for A in "$@"; do
    if [ -n "$NEXT" ]; then
        case "$NEXT" in
            out) OUT="$A" ;;
            data) BODY="$A" ;;
        esac
        NEXT=""
        continue
    fi
    case "$A" in
        -o) NEXT="out" ;;
        --data-binary) NEXT="data" ;;
        -w) WANT_CODE=1 ;;
        -X) POST=1 ;;
        http*) URL="$A" ;;
    esac
done

# a download of the bridge is passed through to the real stage server
case "$URL" in
    *8899/hermes_bridge.py) exec /usr/bin/curl "$@" ;;
esac

HEALTH='{"ok":true,"bridge":"2026-11-19f","hermes":"cli","hermes_available":true,"hermes_error":"","hermes_errors":[],"hermes_model":"base","hermes_models":{"agent_model":"qwen3.8-27b-hermes","source":"config.model.default","pinned":"base","config_default":"qwen3.8-27b-hermes","cli_models":["qwen3.8-27b-hermes"]},"hermes_report":"AI Agent initialized with model: qwen3.8-27b-hermes","hermes_tail":"tool web_search was used","stt":"whisper","tts":"mmx"}'
CHAT='{"reply":"The Raptors are 12-8 and in the playoff picture."}'

case "$URL" in
    */chat)
        printf '%s' "$BODY" >> "$CHAT_LOG"
        if [ -n "$OUT" ]; then printf '%s' "$CHAT" > "$OUT"; else printf '%s' "$CHAT"; fi
        [ "$WANT_CODE" = "1" ] && printf '200'
        exit 0
        ;;
    *)
        if [ -n "$OUT" ]; then printf '%s' "$HEALTH" > "$OUT"; else printf '%s' "$HEALTH"; fi
        [ "$WANT_CODE" = "1" ] && printf '200'
        exit 0
        ;;
esac
SH
chmod +x "$BIN/curl"

# ---------------------------------------------------------- run the script

echo "--- running the script"
OUT=$(PATH="$BIN:$PATH" HOME="$HOME_DIR" ORB_STAGE="http://127.0.0.1:8899" \
      bash "$SCRIPT" 2>&1)
echo "$OUT" | sed 's/^/    /' | head -70

# ------------------------------------------------------------- the checks

check "the current bridge was installed" \
    "$(grep -q "2026-11-19f" "$HOME_DIR/orb-hermes/hermes_bridge.py" && echo 1 || echo 0)" \
    "$(grep -o "2026-11-19[a-z]" "$HOME_DIR/orb-hermes/hermes_bridge.py" | head -1)"

check "the old bridge was kept as a backup" \
    "$(ls "$HOME_DIR/orb-hermes/" | grep -q "bak-" && echo 1 || echo 0)"

check "the agent model is shown" \
    "$(echo "$OUT" | grep -q "qwen3.8-27b-hermes" && echo 1 || echo 0)"

check "it says where the model came from" \
    "$(echo "$OUT" | grep -q "config.model.default" && echo 1 || echo 0)"

check "the question reached the agent" \
    "$(grep -q "Toronto Raptors" "$CHAT_LOG" && echo 1 || echo 0)" \
    "$(head -c 120 "$CHAT_LOG")"

check "the answer is shown" \
    "$(echo "$OUT" | grep -q "playoff picture" && echo 1 || echo 0)"

check "it says the agent answered" \
    "$(echo "$OUT" | grep -q "the agent answered" && echo 1 || echo 0)"

check "the tools the agent used are named" \
    "$(echo "$OUT" | grep -q "web_search" && echo 1 || echo 0)"

check "the token is never printed" \
    "$(echo "$OUT" | grep -q "test-token-123456" && echo 0 || echo 1)"

check "the secret in the settings is never printed" \
    "$(echo "$OUT" | grep -q "should-never-be-printed" && echo 0 || echo 1)"

check "the service was tried before the hand start" \
    "$(grep -q -- "--user start orb-hermes.service" "$SYSTEMCTL_LOG" && echo 1 || echo 0)"

check "exactly one bridge is running" \
    "$(pgrep -f "$HOME_DIR/orb-hermes/hermes_bridge.py" 2>/dev/null | wc -l | tr -d ' ' | grep -q '^1$' && echo 1 || echo 0)" \
    "$(pgrep -af "$HOME_DIR/orb-hermes/hermes_bridge.py" 2>/dev/null | wc -l | tr -d ' ')"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL AGENT VERIFY SCRIPT TESTS PASS"
    exit 0
fi
echo "AGENT VERIFY SCRIPT: $FAILURES FAILURE(S)"
exit 1
