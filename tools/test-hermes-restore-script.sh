#!/usr/bin/env bash
#
# test-hermes-restore-script.sh - check BEELINK-HERMES-RESTORE.sh before it
# is sent to a machine we cannot reach.
#
# The script changes the settings of a live agent and restarts the gateway,
# so it has to be right the first time. This runs it against a fake home
# folder, a fake Hermes and a fake systemd, and checks that:
#
#   * the broken settings file is put back the way it was, with the model
#     inside "default:" and not on the "model:" line,
#   * a file with no good copy is repaired where it lies,
#   * the gateway is restarted as a systemd service,
#   * a process whose command line merely contains the word "gateway" is
#     NOT killed - that is what took the real gateway down,
#   * no secret is ever printed.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${1:-$HERE/../BEELINK-HERMES-RESTORE.sh}"
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

echo "HERMES RESTORE SANDBOX"

BIN="$WORK/bin"
mkdir -p "$BIN"

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

# ------------------------------------------------------------ the fake tools

cat > "$BIN/hermes" <<'SH'
#!/usr/bin/env bash
case "$1" in
  "chat")
    echo "Query: Reply with exactly: HELLO"
    echo "☤ Hermes"
    echo "HELLO"
    exit 0
    ;;
  "config")
    echo "the settings file is valid"
    exit 0
    ;;
  "logs")
    echo "gateway log line: connecting with token 000000000:FAKE_TOKEN_FOR_TESTS_000000"
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$BIN/hermes"

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
        echo "orb-hermes.service enabled"
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
            *status*) echo "hermes-gateway.service - Hermes Agent Gateway"; echo "   Active: active (running)"; exit 0 ;;
            *Description*) echo "Hermes Agent Gateway - Messaging Platform Integration"; exit 0 ;;
            *restart*) echo "restarted"; exit 0 ;;
        esac
        exit 0
        ;;
    orb-hermes.service)
        case "$ALL" in
            *is-active*) echo "inactive"; exit 3 ;;
        esac
        exit 0
        ;;
esac
exit 0
SH
chmod +x "$BIN/systemctl"

cat > "$BIN/journalctl" <<'SH'
#!/usr/bin/env bash
echo "Nov 18 16:50:01 beelink systemd[1]: Started Hermes Agent Gateway."
echo "Nov 18 16:50:02 beelink hermes[123]: Telegram connected."
exit 0
SH
chmod +x "$BIN/journalctl"

# a curl that never touches the network
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
    *11434/api/tags*) BODY='{"models":[{"name":"qwen3.5-hermes:9b"},{"name":"llama3.1:8b"}]}' ;;
    *api.telegram.org*) BODY='{"ok":true,"result":{"username":"hermes_bot"}}' ;;
    *8642*) BODY='{"data":[]}' ;;
    *8787*) BODY='{"bridge":"2026-11-17h","hermes":"api-server","hermes_available":true}' ;;
esac
if [ -n "$OUT" ]; then printf '%s' "$BODY" > "$OUT"; else printf '%s' "$BODY"; fi
[ "$WANT_CODE" = "1" ] && printf '200'
exit 0
SH
chmod +x "$BIN/curl"

# ------------------------------------------------------- the broken settings
#
# This is the exact damage: the model was written onto the "model:" line, so
# YAML has a plain value on line 1 and a nested block on line 2.

BROKEN='model:'"'"'qwen3.8-27b-hermes'"'"'
    default: '"'"'qwen3.8-27b-hermes'"'"'
    provider: custom
    base_url: http://localhost:11434/v1
    context_length: 65536
    max_tokens: 16384
telegram:
  bot_token: 000000000:FAKE_TOKEN_FOR_TESTS_000000'

GOOD='model:
  default: qwen3.8-27b-hermes
  provider: custom
  base_url: http://localhost:11434/v1
  context_length: 65536
  max_tokens: 16384
telegram:
  bot_token: 000000000:FAKE_TOKEN_FOR_TESTS_000000'

# ------------------------------------------------------------------ scenario 1
# the good copy is there: it must be put back

echo
echo "--- scenario 1: the copy from before the damage is there"

H1="$WORK/home1"
mkdir -p "$H1/.hermes"
printf '%s\n' "$BROKEN" > "$H1/.hermes/config.yaml"
printf '%s\n' "$GOOD" > "$H1/.hermes/config.yaml.bak-20261118-160000"

export SYSTEMCTL_LOG="$WORK/systemctl1.log"
: > "$SYSTEMCTL_LOG"

OUT=$(PATH="$BIN:$PATH" HOME="$H1" bash "$SCRIPT" 2>&1)
echo "$OUT" | sed 's/^/    /' | head -60

CFG1="$H1/.hermes/config.yaml"

check "the settings file parses again" \
    "$("$PY" -c "
import sys, yaml
yaml.safe_load(open('$CFG1', encoding='utf-8'))
print(1)" 2>/dev/null || echo "$YAML_FAIL")"

check "the model is inside model.default, not on the model line" \
    "$("$PY" -c "
import yaml
data = yaml.safe_load(open('$CFG1', encoding='utf-8'))
model = data.get('model')
print(1 if isinstance(model, dict) and model.get('default') else 0)" 2>/dev/null || echo "$YAML_FAIL")" \
    "$(grep -n 'model' "$CFG1" | head -4 | tr '\n' ' ')"

check "the provider and the base url survived" \
    "$("$PY" -c "
import yaml
data = yaml.safe_load(open('$CFG1', encoding='utf-8'))
model = data.get('model') or {}
print(1 if model.get('provider') == 'custom' and model.get('base_url') else 0)" 2>/dev/null || echo "$YAML_FAIL")"

check "the telegram token survived" \
    "$("$PY" -c "
import yaml
data = yaml.safe_load(open('$CFG1', encoding='utf-8'))
print(1 if (data.get('telegram') or {}).get('bot_token') else 0)" 2>/dev/null || echo "$YAML_FAIL")"

check "the gateway was restarted as a service" \
    "$(grep -q -- "--user restart hermes-gateway.service" "$SYSTEMCTL_LOG" && echo 1 || echo 0)" \
    "$(cat "$SYSTEMCTL_LOG" | tr '\n' ' ')"

check "the broken file was kept" \
    "$(ls "$H1/.hermes/" | grep -q "config.yaml.broken-" && echo 1 || echo 0)"

check "the telegram token is never printed" \
    "$(echo "$OUT" | grep -q "AAsecrettokenvalue" && echo 0 || echo 1)"

check "the token is masked instead" \
    "$(echo "$OUT" | grep -q "<telegram-token>" && echo 1 || echo 0)"

# ------------------------------------------------------------------ scenario 2
# there is no good copy: the file has to be repaired where it lies

echo
echo "--- scenario 2: no copy to put back, the file is repaired"

H2="$WORK/home2"
mkdir -p "$H2/.hermes"
printf '%s\n' "$BROKEN" > "$H2/.hermes/config.yaml"

export SYSTEMCTL_LOG="$WORK/systemctl2.log"
: > "$SYSTEMCTL_LOG"

OUT2=$(PATH="$BIN:$PATH" HOME="$H2" bash "$SCRIPT" 2>&1)
CFG2="$H2/.hermes/config.yaml"

check "the settings file parses again" \
    "$("$PY" -c "
import yaml
yaml.safe_load(open('$CFG2', encoding='utf-8'))
print(1)" 2>/dev/null || echo "$YAML_FAIL")" \
    "$(head -3 "$CFG2" | tr '\n' ' ')"

check "the model went into model.default" \
    "$("$PY" -c "
import yaml
data = yaml.safe_load(open('$CFG2', encoding='utf-8'))
model = data.get('model')
print(1 if isinstance(model, dict) and model.get('default') else 0)" 2>/dev/null || echo "$YAML_FAIL")" \
    "$(head -3 "$CFG2" | tr '\n' ' ')"

check "the model line carries no value of its own" \
    "$(grep -qE '^model:[ \t]*$' "$CFG2" && echo 1 || echo 0)" \
    "$(grep -nE '^model' "$CFG2" | tr '\n' ' ')"

# ------------------------------------------------------------------ scenario 3
# the one that took the real gateway down: a process whose command line
# merely contains the word "gateway" must not be killed

echo
echo "--- scenario 3: a helper with the word gateway in its command line"

H3="$WORK/home3"
mkdir -p "$H3/.hermes"
printf '%s\n' "$BROKEN" > "$H3/.hermes/config.yaml"
printf '%s\n' "$GOOD" > "$H3/.hermes/config.yaml.bak-20261118-160000"

export SYSTEMCTL_LOG="$WORK/systemctl3.log"
: > "$SYSTEMCTL_LOG"

# the hermes CLI helper - its command line contains "gateway", and it is not
# the gateway
bash -c 'exec -a "hermes gateway helper --status" sleep 300' >/dev/null 2>&1 &
HELPER_PID=$!
PIDS_TO_KILL="$PIDS_TO_KILL $HELPER_PID"
sleep 1

OUT3=$(PATH="$BIN:$PATH" HOME="$H3" bash "$SCRIPT" 2>&1)

sleep 1
check "the helper with gateway in its command line is still alive" \
    "$(kill -0 "$HELPER_PID" 2>/dev/null && echo 1 || echo 0)"

check "nothing was killed by hand" \
    "$(grep -qE "kill|pkill" <<< "$OUT3" && echo 0 || echo 1)" \
    "$(grep -E "kill|pkill" <<< "$OUT3" | head -3 | tr '\n' ' ')"

check "no python -c command line was copied out of /proc" \
    "$(grep -qE "python.*-c .*import" <<< "$OUT3" && echo 0 || echo 1)"

check "the gateway was restarted through systemd" \
    "$(grep -q -- "--user restart hermes-gateway.service" "$SYSTEMCTL_LOG" && echo 1 || echo 0)"

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL HERMES RESTORE SCRIPT TESTS PASS"
    exit 0
fi
echo "HERMES RESTORE SCRIPT: $FAILURES FAILURE(S)"
exit 1
