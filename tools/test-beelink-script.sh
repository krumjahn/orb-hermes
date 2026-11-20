#!/usr/bin/env bash
#
# test-beelink-script.sh - check BEELINK-BRIDGE-UPDATE.sh before it is sent
# to a machine we cannot reach.
#
# The script has to work on the first try, because the only way to run it is
# on the Beelink, by hand. This runs it against a fake bridge process and a
# fake /proc, and checks that it:
#
#   * finds the file the running bridge actually uses,
#   * replaces it and keeps a backup,
#   * restarts the process when no service manages it,
#   * waits for the new build to show up in /health,
#   * and says so when it is done.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
SCRIPT="${1:-$HERE/../BEELINK-BRIDGE-UPDATE.sh}"
if [ ! -f "$SCRIPT" ]; then
    echo "the script to test is not there: $SCRIPT" >&2
    exit 1
fi
WORK="$(mktemp -d)"
FAILURES=0

# the version the script expects - read it, so it never goes stale
EXPECTED_VERSION="$(sed -nE 's/^EXPECTED_VERSION="([^"]+)".*/\1/p' "$SCRIPT" | head -1)"
[ -n "$EXPECTED_VERSION" ] || EXPECTED_VERSION="unknown"
echo "the script expects the bridge version: $EXPECTED_VERSION"

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
    # the script may have started a new bridge - it has to go too
    if [ -n "${SANDBOX:-}" ]; then
        pkill -f "$SANDBOX/hermes_bridge.py" 2>/dev/null
        pkill -f "$SANDBOX/relay_dialer.py" 2>/dev/null
    fi
    [ -n "${FAKE_PID:-}" ] && kill "$FAKE_PID" 2>/dev/null
    [ -n "${FAKE_DIALER_PID:-}" ] && kill "$FAKE_DIALER_PID" 2>/dev/null
    [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "BEELINK SCRIPT SANDBOX"

# ---------------------------------------------------- the fake bridge process

SANDBOX="$WORK/orb-hermes"
mkdir -p "$SANDBOX"

# the file the "running" bridge uses - it starts life as an older copy, with
# a version marker of its own. The script has to replace it on the version,
# not on the mere presence of a marker.
cat > "$SANDBOX/hermes_bridge.py" <<'PY'
#!/usr/bin/env python3
"""A stand-in for the bridge: it just stays alive."""
import time

BRIDGE_VERSION = os.environ.get("BRIDGE_VERSION", "2026-11-17b").strip()

while True:
    time.sleep(1)
PY
chmod +x "$SANDBOX/hermes_bridge.py"

# a process whose command line looks like the real one
bash -c 'exec -a "python3 '"$SANDBOX"'/hermes_bridge.py" sleep 300' >/dev/null 2>&1 &
FAKE_PID=$!
sleep 1

# the fake /proc entry for it
mkdir -p "$WORK/proc/$FAKE_PID"
printf 'python3\0%s\0' "$SANDBOX/hermes_bridge.py" > "$WORK/proc/$FAKE_PID/cmdline"
# the real bridge takes a port, so the restarted one gets a free one - the
# script puts these settings back when it restarts the process
BRIDGE_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
printf 'HERMES_PREFER=auto\0HERMES_MODEL=hermes-agent\0MMX_VOICE=English_SereneWoman\0BRIDGE_PORT=%s\0PATH=/usr/bin:/bin:/usr/sbin:/sbin\0' \
    "$BRIDGE_PORT" > "$WORK/proc/$FAKE_PID/environ"
ln -s "$SANDBOX" "$WORK/proc/$FAKE_PID/cwd"

# the relay dialer runs on the same machine - it has a timeout of its own
cat > "$SANDBOX/relay_dialer.py" <<'PY'
#!/usr/bin/env python3
"""A stand-in for the relay dialer."""
import time
while True:
    time.sleep(1)
PY
chmod +x "$SANDBOX/relay_dialer.py"

bash -c 'exec -a "python3 '"$SANDBOX"'/relay_dialer.py 127.0.0.1 9 test-token 8787" sleep 300' >/dev/null 2>&1 &
FAKE_DIALER_PID=$!
sleep 1

mkdir -p "$WORK/proc/$FAKE_DIALER_PID"
# the arguments are NUL separated, like a real process
python3 - "$WORK/proc/$FAKE_DIALER_PID/cmdline" "$SANDBOX/relay_dialer.py" <<'PY'
import sys
path, script = sys.argv[1], sys.argv[2]
with open(path, "wb") as fh:
    fh.write(b"python3\x00" + script.encode() +
             b"\x00127.0.0.1\x009\x00test-token\x008787\x00")
PY
printf 'TOKEN=test-token\0PATH=/usr/bin:/bin:/usr/sbin:/sbin\0' > "$WORK/proc/$FAKE_DIALER_PID/environ"
ln -s "$SANDBOX" "$WORK/proc/$FAKE_DIALER_PID/cwd"

# ------------------------------------------------ the stub the script talks to

STUB_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
sed "s/__VERSION__/$EXPECTED_VERSION/" > "$WORK/stub.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({
            "ok": True, "bridge": "__VERSION__", "hermes": "cli",
            "hermes_available": True, "hermes_error": "", "hermes_model": "",
            "hermes_settings": {}, "hermes_report": "",
            "stt": "whisper", "tts": "mmx", "token_required": True,
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = json.dumps({"reply": "HELLO"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$WORK/stub.py" "$STUB_PORT" &
STUB_PID=$!
sleep 1

# ------------------------------------------------------------- run the script

# the staging server is a local one serving this repo's own beelink folder,
# so the script downloads the real bridge without needing a server running
# somewhere else; only the relay is the stub
STAGE_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 -m http.server "$STAGE_PORT" --bind 127.0.0.1 \
    --directory "$HERE/../beelink" >/dev/null 2>&1 &
STAGE_PID=$!
sleep 1

TEST_SCRIPT="$WORK/script.sh"
sed -e "s|^RELAY=.*|RELAY=\"http://127.0.0.1:$STUB_PORT\"|" \
    -e "s|^TOKEN=.*|TOKEN=\"test-token\"|" \
    -e "s|^MAC=.*|MAC=\"http://127.0.0.1:$STAGE_PORT\"|" \
    "$SCRIPT" > "$TEST_SCRIPT"

echo "--- running the script"
OUT=$(PROC="$WORK/proc" HOME="$WORK/home" bash "$TEST_SCRIPT" 2>&1)
echo "$OUT" | sed 's/^/    /' | head -140

# ------------------------------------------------------------------ the checks

check "the script found the file the bridge is running" \
    "$(echo "$OUT" | grep -q "the running file is: $SANDBOX/hermes_bridge.py" && echo 1 || echo 0)"

check "the running file was replaced with the new bridge" \
    "$(grep -q "$EXPECTED_VERSION" "$SANDBOX/hermes_bridge.py" && echo 1 || echo 0)"

check "an older bridge with a version marker is still replaced" \
    "$(grep -q "$EXPECTED_VERSION" "$SANDBOX/hermes_bridge.py" && ! grep -q "2026-11-17b" "$SANDBOX/hermes_bridge.py" && echo 1 || echo 0)"

check "a backup was kept" \
    "$(ls "$SANDBOX" | grep -q "bak-" && echo 1 || echo 0)" \
    "$(ls "$SANDBOX" | tr '\n' ' ')"

check "the new build was seen in /health" \
    "$(echo "$OUT" | grep -q "the new bridge is running (version $EXPECTED_VERSION)" && echo 1 || echo 0)"

check "the proof came back clean" \
    "$(echo "$OUT" | grep -q "CLEAN - the orb will only speak the answer" && echo 1 || echo 0)"

check "the settings of the running process were shown" \
    "$(echo "$OUT" | grep -q "HERMES_PREFER=auto" && echo 1 || echo 0)"

# the restarted process must be a new one
sleep 1
NEW_PID=$(pgrep -f "$SANDBOX/hermes_bridge.py" | head -1)
check "the bridge process was restarted" \
    "$([ -n "$NEW_PID" ] && [ "$NEW_PID" != "$FAKE_PID" ] && echo 1 || echo 0)" \
    "old=$FAKE_PID new=$NEW_PID"

check "the dialer was updated with the long timeout" \
    "$(grep -q "BRIDGE_TIMEOUT = 420.0" "$SANDBOX/relay_dialer.py" && echo 1 || echo 0)"

check "the dialer was found and reported" \
    "$(echo "$OUT" | grep -q "the dialer runs from" && echo 1 || echo 0)"

# The model that gets written into ~/.hermes/config.yaml has to be quoted.
# An unquoted value with a ": " in it stops the file from parsing, and
# Hermes then runs on its default settings - which have no model - so the
# agent and the Telegram gateway both fail.
check "the model is written into the settings in quotes" \
    "$(grep -qF "replace(\"'\", \"''\")" "$SCRIPT" && echo 1 || echo 0)"

check "a model name with a space in it is never used" \
    "$(grep -q "isspace()" "$SCRIPT" && echo 1 || echo 0)"

check "the settings are checked after the model is written" \
    "$(grep -q "the settings file still parses" "$SCRIPT" && echo 1 || echo 0)"

# The model must never be written onto the "model:" line when that line is
# the key of a block. That is what broke the settings file: YAML was left
# with a value on line 1 and a nested block on line 2, and stopped parsing.
check "the model is never written onto the model key line" \
    "$(grep -qF "re.sub(r'(?m)^([ \t]*model" "$SCRIPT" && echo 0 || echo 1)"

check "the empty model line is no longer used as a place to write" \
    "$(grep -qF 'model[[:space:]]*:[[:space:]]*["' "$SCRIPT" && echo 0 || echo 1)"

check "the model goes into model.default" \
    "$(grep -qF 'default[ \t]*:' "$SCRIPT" && echo 1 || echo 0)"

check "the place of the model is checked afterwards" \
    "$(grep -q "the model is where Hermes looks for it" "$SCRIPT" && echo 1 || echo 0)"

# The real test: take the writer out of the script and run it on a real
# settings file. This is the one that broke the gateway.
WRITE_MODEL="$WORK/write_model.py"
awk '/python3 - "\$CFG" "\$MODEL" <<.PY.$/{flag=1; next} flag && /^PY$/{flag=0} flag' \
    "$SCRIPT" > "$WRITE_MODEL"

if [ -s "$WRITE_MODEL" ]; then
    check "the model writer was found in the script" \
        "$(grep -q "model_block\|default" "$WRITE_MODEL" && echo 1 || echo 0)"

    cat > "$WORK/model-test.yaml" <<'YAML'
model:
  default: qwen3.8-27b-hermes
  provider: custom
  base_url: http://localhost:11434/v1
  context_length: 65536
  max_tokens: 16384
telegram:
  bot_token: 000000000:FAKE_TOKEN_FOR_TESTS_000000
YAML

    python3 "$WRITE_MODEL" "$WORK/model-test.yaml" "qwen3.5-hermes:9b" >/dev/null 2>&1

    check "the settings still parse after the model was written" \
        "$("$PY" -c "
import yaml
yaml.safe_load(open('$WORK/model-test.yaml', encoding='utf-8'))
print(1)" 2>/dev/null || echo "$YAML_FAIL")" \
        "$(head -4 "$WORK/model-test.yaml" | tr '\n' ' ')"

    check "the model line carries no value of its own" \
        "$(grep -qE '^model:[ \t]*$' "$WORK/model-test.yaml" && echo 1 || echo 0)" \
        "$(grep -nE '^model' "$WORK/model-test.yaml" | tr '\n' ' ')"

    check "the model landed in model.default" \
        "$("$PY" -c "
import yaml
data = yaml.safe_load(open('$WORK/model-test.yaml', encoding='utf-8'))
print(1 if data['model']['default'] == 'qwen3.5-hermes:9b' else 0)" 2>/dev/null || echo "$YAML_FAIL")" \
        "$(sed -n '1,3p' "$WORK/model-test.yaml" | tr '\n' ' ')"

    check "the provider, the base url and the token survived" \
        "$("$PY" -c "
import yaml
data = yaml.safe_load(open('$WORK/model-test.yaml', encoding='utf-8'))
model = data['model']
ok = (model.get('provider') == 'custom'
      and model.get('base_url') == 'http://localhost:11434/v1'
      and data['telegram']['bot_token'])
print(1 if ok else 0)" 2>/dev/null || echo "$YAML_FAIL")"
else
    check "the model writer was found in the script" 0 "the heredoc was not found"
fi

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "BEELINK SCRIPT SANDBOX: $FAILURES FAILURE(S)"
    exit 1
fi
echo "ALL BEELINK SCRIPT SANDBOX TESTS PASS"
