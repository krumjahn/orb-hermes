#!/usr/bin/env bash
#
# test-hermes-diag-script.sh - check BEELINK-HERMES-DIAG.sh before it is sent
# to a machine we cannot reach.
#
# This script must only LOOK. The version before this one restarted the
# gateway by killing every process whose command line contained the word
# "gateway" - and the Hermes CLI has a helper with that word in it. The
# helper was killed, and the real gateway with it.
#
# So the checks here are:
#
#   * the settings file is not touched,
#   * no process is killed and nothing is started,
#   * the gateway is found as a systemd service,
#   * a helper with the word "gateway" in its command line survives,
#   * no secret is printed.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-$HERE/../BEELINK-HERMES-DIAG.sh}"
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
    elif [ "$2" = "-" ]; then
        # the check needs something this machine does not have
        printf '  SKIP  %s  %s\n' "$1" "${3:-}"
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

echo "HERMES DIAGNOSTIC SANDBOX"

HOME_DIR="$WORK/home"
BIN="$WORK/bin"
mkdir -p "$HOME_DIR/.hermes" "$BIN"

# ------------------------------------------- a broken settings file

cat > "$HOME_DIR/.hermes/config.yaml" <<'YAML'
# Hermes settings
model: qwen3.8-27b-hermes: latest
provider: ollama
telegram:
  bot_token: 000000000:FAKE_TOKEN_FOR_TESTS_000000
YAML

CFG="$HOME_DIR/.hermes/config.yaml"
BEFORE=$(md5 -q "$CFG" 2>/dev/null || md5sum "$CFG" | cut -d' ' -f1)

# a Python that can read YAML - the system one usually cannot
. "$HERE/yaml-python.sh"
PY="$(yaml_python "$HERE/..")"
if [ -z "$PY" ]; then
    echo "no Python with PyYAML found - the YAML checks will be skipped."
    echo "Install PyYAML, or set ORB_YAML_PYTHON to a Python that has it."
fi
# "-" means skip: this machine has no YAML parser at all
YAML_FAIL="-"
[ -n "$PY" ] && YAML_FAIL="0"
export PY

# --------------------------------------------------- the hermes CLI stub

cat > "$BIN/hermes" <<'SH'
#!/usr/bin/env bash
case "$1" in
  "config")
    echo "the settings file is valid"
    exit 0
    ;;
  "chat")
    echo "Query: Reply with exactly: HELLO"
    echo "☤ Hermes"
    echo "HELLO"
    exit 0
    ;;
  "logs")
    echo "gateway log line: connecting with token 000000000:FAKE_TOKEN_FOR_TESTS_000000"
    exit 0
    ;;
  "gateway")
    echo "gateway started" >> "$GATEWAY_LOG"
    exec sleep 300
    ;;
esac
exit 0
SH
chmod +x "$BIN/hermes"

export GATEWAY_LOG="$WORK/gateway.log"
: > "$GATEWAY_LOG"

# ------------------------------------------------------- the systemd stub

cat > "$BIN/systemctl" <<'SH'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SYSTEMCTL_LOG"
ALL="$*"
case "$ALL" in
    *"list-units"*) exit 0 ;;
esac
case "$ALL" in
    *"list-unit-files"*)
        echo "hermes-gateway.service enabled"
        echo "hermes-notes.service enabled"
        exit 0
        ;;
esac
UNIT=""
for A in "$@"; do
    case "$A" in *.service) UNIT="$A" ;; esac
done
case "$UNIT" in
    hermes-gateway.service)
        case "$ALL" in
            *is-enabled*) echo "enabled"; exit 0 ;;
            *is-active*) echo "active"; exit 0 ;;
            *status*) echo "hermes-gateway.service - Hermes Agent Gateway"; exit 0 ;;
            *Description*) echo "Hermes Agent Gateway - Messaging Platform Integration"; exit 0 ;;
            *ExecStart*) echo "/usr/bin/hermes gateway --daemon"; exit 0 ;;
        esac
        exit 0
        ;;
esac
exit 0
SH
chmod +x "$BIN/systemctl"

cat > "$BIN/journalctl" <<'SH'
#!/usr/bin/env bash
echo "Nov 18 16:50:01 beelink hermes[123]: Telegram connected."
exit 0
SH
chmod +x "$BIN/journalctl"

cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
URL=""; OUT=""; WANT_CODE=0
PREV=""
for A in "$@"; do
    case "$PREV" in
        -o) OUT="$A" ;;
    esac
    [ "$A" = "-w" ] && WANT_CODE=1
    case "$A" in http*) URL="$A" ;; esac
    PREV="$A"
done
BODY='{}'
case "$URL" in
    *api.telegram.org*) BODY='{"ok":true,"result":{"username":"hermes_bot"}}' ;;
    *8642*) BODY='{"data":[]}' ;;
    *11434*) BODY='{"models":[{"name":"qwen3.5-hermes:9b"}]}' ;;
esac
if [ -n "$OUT" ]; then printf '%s' "$BODY" > "$OUT"; else printf '%s' "$BODY"; fi
[ "$WANT_CODE" = "1" ] && printf '200'
exit 0
SH
chmod +x "$BIN/curl"

# ------------------------------------------- a helper that says gateway

bash -c 'exec -a "hermes gateway helper --status" sleep 300' >/dev/null 2>&1 &
HELPER_PID=$!
PIDS_TO_KILL="$PIDS_TO_KILL $HELPER_PID"
sleep 1

export SYSTEMCTL_LOG="$WORK/systemctl.log"
: > "$SYSTEMCTL_LOG"

# ---------------------------------------------------------- run the script

echo "--- running the script"
OUT=$(PATH="$BIN:$PATH" HOME="$HOME_DIR" bash "$SCRIPT" 2>&1)
echo "$OUT" | sed 's/^/    /' | head -70

# ------------------------------------------------------------- the checks

AFTER=$(md5 -q "$CFG" 2>/dev/null || md5sum "$CFG" | cut -d' ' -f1)

check "the settings file was not touched" \
    "$([ "$BEFORE" = "$AFTER" ] && echo 1 || echo 0)"

check "the helper with gateway in its command line is still alive" \
    "$(kill -0 "$HELPER_PID" 2>/dev/null && echo 1 || echo 0)"

check "nothing was killed by hand" \
    "$(grep -qE "kill |pkill|kill -" <<< "$OUT" && echo 0 || echo 1)" \
    "$(grep -E "kill |pkill" <<< "$OUT" | head -3 | tr '\n' ' ')"

check "nothing was started" \
    "$(grep -q "gateway started" "$GATEWAY_LOG" && echo 0 || echo 1)" \
    "$(cat "$GATEWAY_LOG" | tr '\n' ' ')"

check "no service was restarted" \
    "$(grep -q -- "--user restart" "$SYSTEMCTL_LOG" && echo 0 || echo 1)" \
    "$(cat "$SYSTEMCTL_LOG" | tr '\n' ' ')"

check "no python -c command line was copied out of /proc" \
    "$(grep -qE "python.*-c .*import" <<< "$OUT" && echo 0 || echo 1)"

check "the gateway was found as a service" \
    "$(echo "$OUT" | grep -q "the gateway is the service: hermes-gateway.service" && echo 1 || echo 0)" \
    "$(echo "$OUT" | grep -i "gateway" | head -3 | tr '\n' ' ')"

check "the agent was tested" \
    "$(echo "$OUT" | grep -q "Does the agent answer" && echo 1 || echo 0)"

check "the telegram token is never printed" \
    "$(echo "$OUT" | grep -q "AAsecrettokenvalue" && echo 0 || echo 1)"

check "the token is masked instead" \
    "$(echo "$OUT" | grep -q "<telegram-token>" && echo 1 || echo 0)"

check "the processes are listed" \
    "$(echo "$OUT" | grep -qE "every hermes process" && echo 1 || echo 0)"

check "the logs are shown" \
    "$(echo "$OUT" | grep -qE "The logs|hermes logs" && echo 1 || echo 0)"

check "telegram itself was checked" \
    "$(echo "$OUT" | grep -q "telegram getMe" && echo 1 || echo 0)"

check "it says that it only looked" \
    "$(echo "$OUT" | grep -q "it changed nothing" && echo 1 || echo 0)"

check "it points at the script that does the fixing" \
    "$(echo "$OUT" | grep -q "BEELINK-HERMES-RESTORE.sh" && echo 1 || echo 0)"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL HERMES DIAGNOSTIC SCRIPT TESTS PASS"
    exit 0
fi
echo "HERMES DIAGNOSTIC SCRIPT: $FAILURES FAILURE(S)"
exit 1
