#!/usr/bin/env bash
#
# BEELINK-AGENT-VERIFY.sh - put the current bridge in place and prove that
# the orb really talks to the Hermes agent - the one with the tools, the web
# search and the memory - and not to a plain model server.
#
# Run this ON the Beelink:
#
#     curl -fsSL http://192.168.1.10:8899/BEELINK-AGENT-VERIFY.sh | bash
#
# What was wrong
# ---------------
# The bridge pinned the agent's model to "base" - that is the SIZE of a
# speech model, not an agent. The agent then had no model at all and answered
# "model is required" every time, so the bridge quietly fell back to Ollama.
# Ollama answers from the prompt alone: no web search, no tools, no memory of
# its own. That is why the orb could not look anything up while Telegram,
# which runs the same agent with the same settings file, could.
#
# What this script does
# ----------------------
#   1. shows the model the agent's own settings file names,
#   2. stops every bridge and puts the current one in place,
#   3. starts exactly one bridge - by the service when the service works, by
#      hand when it does not,
#   4. asks the agent a question that needs the web,
#   5. says which backend answered: the agent, or the fallback.
#
# It never prints a secret, and it can be run more than once.
#
set -uo pipefail

STAGE="${ORB_STAGE:-http://192.168.1.10:8899}"
BRIDGE_DIR="${ORB_BRIDGE_DIR:-$HOME/orb-hermes}"
BRIDGE_FILE="$BRIDGE_DIR/hermes_bridge.py"
RUN_SCRIPT="$BRIDGE_DIR/run-bridge.sh"
UNIT="orb-hermes.service"
EXPECTED_VERSION="2026-11-23b"
QUESTION="${ORB_QUESTION:-How are the Toronto Raptors doing this season?}"
STAMP="$(date +%Y%m%d-%H%M%S)"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    %s\n' "$*"; }
bad()  { printf '\033[1;31m    %s\n' "$*"; }
ok()   { printf '\033[1;32m    %s\n' "$*"; }

# ------------------------------------------------- 1. the agent's settings

say "1. The model the agent is configured to use"

CFG="$HOME/.hermes/config.yaml"
if [ -f "$CFG" ]; then
    info "the settings file: $CFG"
    python3 - "$CFG" <<'PY' 2>/dev/null || warn "the model block could not be read"
import re
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().split("\n")
except OSError:
    sys.exit(1)

block = []
inside = False
for line in lines:
    if re.match(r"^model[ \t]*:", line):
        inside = True
        block.append(line)
        continue
    if inside:
        if not line.strip():
            continue
        if not line[:1].isspace():
            break
        block.append(line)

for line in block:
    if re.search(r"(?i)key|token|secret|password", line):
        continue
    print("      %s" % line.strip())
if not block:
    print("      (there is no model: block in the settings file)")
PY
else
    warn "no settings file at $CFG"
fi

# ------------------------------------------------- 2. what is running now

say "2. What is running right now"

pgrep -af 'hermes_bridge.py' 2>/dev/null | sed 's/^/      /' || true
if systemctl --user is-enabled "$UNIT" >/dev/null 2>&1; then
    info "the service $UNIT is $(systemctl --user is-enabled "$UNIT" 2>/dev/null)"
    info "  it is $(systemctl --user is-active "$UNIT" 2>/dev/null)"
else
    info "the service $UNIT is not enabled"
fi

if [ -f "$BRIDGE_FILE" ]; then
    OLD_VERSION=$(grep -m1 'BRIDGE_VERSION[[:space:]]*=' "$BRIDGE_FILE" 2>/dev/null \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[a-z]?' | head -1)
    info "the bridge on this machine: ${OLD_VERSION:-unknown}"
else
    info "there is no bridge at $BRIDGE_FILE yet"
fi

# the token is needed for the health check and for the question - it is
# taken from the run script, and from the running process when that does
# not have it. It is never printed.
TOKEN=""
if [ -f "$RUN_SCRIPT" ]; then
    TOKEN=$(sed -n 's/^export BRIDGE_TOKEN=//p' "$RUN_SCRIPT" 2>/dev/null | head -1 | tr -d '"'"'"'')
fi
if [ -z "$TOKEN" ]; then
    for PID in $(pgrep -f 'hermes_bridge.py' 2>/dev/null); do
        if [ -r "/proc/$PID/environ" ]; then
            TOKEN=$(tr '\0' '\n' < "/proc/$PID/environ" 2>/dev/null \
                | sed -n 's/^BRIDGE_TOKEN=//p' | head -1)
            [ -n "$TOKEN" ] && break
        fi
    done
fi
if [ -n "$TOKEN" ]; then
    info "the token was found"
else
    warn "no token was found - the checks will be skipped"
fi

# ------------------------------------------------- 3. one bridge, one owner

say "3. Stopping everything and putting the current bridge in place"

systemctl --user stop "$UNIT" 2>/dev/null
sleep 2
for PID in $(pgrep -f 'hermes_bridge.py' 2>/dev/null); do
    kill "$PID" 2>/dev/null
done
sleep 3
for PID in $(pgrep -f 'hermes_bridge.py' 2>/dev/null); do
    kill -9 "$PID" 2>/dev/null
done
sleep 1
REMAINING=$(pgrep -f 'hermes_bridge.py' 2>/dev/null | wc -l | tr -d ' ')
if [ "$REMAINING" = "0" ]; then
    info "every bridge process is gone"
else
    warn "$REMAINING process(es) are still there"
fi

if [ -f "$BRIDGE_FILE" ]; then
    cp -p "$BRIDGE_FILE" "$BRIDGE_FILE.bak-$STAMP" 2>/dev/null \
        && info "the old one is kept as $BRIDGE_FILE.bak-$STAMP"
fi

INSTALLED=""
if curl -fsSL -m 60 "$STAGE/hermes_bridge.py" -o "$BRIDGE_FILE.new" 2>/dev/null; then
    if grep -q "$EXPECTED_VERSION" "$BRIDGE_FILE.new" \
        && python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' \
            "$BRIDGE_FILE.new" 2>/dev/null; then
        mv "$BRIDGE_FILE.new" "$BRIDGE_FILE"
        chmod +x "$BRIDGE_FILE" 2>/dev/null
        INSTALLED="$EXPECTED_VERSION"
        info "the current bridge is in place (version $EXPECTED_VERSION)"
    else
        rm -f "$BRIDGE_FILE.new" 2>/dev/null
        bad "the download did not carry version $EXPECTED_VERSION - the old bridge is left"
    fi
else
    rm -f "$BRIDGE_FILE.new" 2>/dev/null
    bad "the bridge could not be downloaded from $STAGE"
fi

STARTED_BY=""
systemctl --user start "$UNIT" 2>/dev/null
sleep 6
if systemctl --user is-active "$UNIT" >/dev/null 2>&1; then
    STARTED_BY="$UNIT"
    info "  the service owns the bridge"
else
    warn "  the service did not come up"
    systemctl --user stop "$UNIT" 2>/dev/null
fi

if [ -z "$STARTED_BY" ] && [ -f "$RUN_SCRIPT" ] && [ -x "$RUN_SCRIPT" ]; then
    warn "starting it by hand from $RUN_SCRIPT instead"
    nohup "$RUN_SCRIPT" >> "$BRIDGE_DIR/bridge.log" 2>&1 &
    STARTED_BY="$RUN_SCRIPT"
    sleep 6
fi

if [ -z "$STARTED_BY" ]; then
    bad "no bridge could be started"
    tail -20 "$BRIDGE_DIR/bridge.log" 2>/dev/null | sed 's/^/      /'
    exit 1
fi
info "the bridge is run by: $STARTED_BY"

# ------------------------------------------------- 4. does it answer

say "4. What does the bridge say about itself"

HEALTH=""
VERSION=""
for TRY in 1 2 3 4 5 6 7 8 9 10; do
    HEALTH=$(curl -s -m 20 "http://127.0.0.1:8787/health" \
        -H "X-Auth-Token: $TOKEN" 2>/dev/null)
    VERSION=$(printf '%s' "$HEALTH" | sed -nE 's/.*"bridge"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')
    [ -n "$VERSION" ] && break
    sleep 3
done

if [ -n "$VERSION" ]; then
    info "the bridge answers: version $VERSION"
    if [ "$VERSION" = "$EXPECTED_VERSION" ]; then
        ok "that is the expected version"
    else
        warn "that is NOT the expected version ($EXPECTED_VERSION)"
    fi
else
    bad "the bridge does not answer"
    tail -20 "$BRIDGE_DIR/bridge.log" 2>/dev/null | sed 's/^/      /'
    exit 1
fi

printf '%s' "$HEALTH" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
models = data.get("hermes_models") or {}
print("      %-18s %s" % ("the backend:", str(data.get("hermes"))[:80]))
print("      %-18s %s" % ("the agent model:", str(models.get("agent_model"))[:80]))
print("      %-18s %s" % ("it came from:", str(models.get("source"))[:80]))
print("      %-18s %s" % ("the pinned one:", str(models.get("pinned"))[:80]))
print("      %-18s %s" % ("the settings:", str(models.get("config_default"))[:80]))
for entry in (models.get("models") or [])[:6]:
    print("      %-18s %s" % ("a model:", "%s (%s)" % (entry.get("model"), entry.get("source"))))
for entry in (models.get("cli_models") or [])[:6]:
    print("      %-18s %s" % ("the CLI will try:", entry))
for key in ("stt", "tts", "hermes_error"):
    if key in data:
        print("      %-18s %s" % (key + ":", str(data[key])[:120]))
for line in (data.get("hermes_errors") or [])[-4:]:
    print("      %-18s %s" % ("why:", str(line)[:150]))
' 2>/dev/null

# ------------------------------------------------- 5. the real question

say "5. Asking the agent a question that needs the web"
info "the question: $QUESTION"
info "this can take a few minutes while the agent loads its tools"

REPLY_FILE="/tmp/orb-agent-verify-reply.json"
rm -f "$REPLY_FILE" 2>/dev/null
HTTP_CODE=$(curl -s -m 420 -o "$REPLY_FILE" -w '%{http_code}' \
    -X POST "http://127.0.0.1:8787/chat" \
    -H "X-Auth-Token: $TOKEN" -H "Content-Type: application/json" \
    --data-binary "$(python3 -c '
import json, sys
print(json.dumps({"text": sys.argv[1], "session": "agent-verify"}))
' "$QUESTION")" 2>/dev/null)
info "the bridge answered with HTTP $HTTP_CODE"

if [ -s "$REPLY_FILE" ]; then
    python3 - "$REPLY_FILE" <<'PY' 2>/dev/null || cat "$REPLY_FILE"
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(0)

reply = str(data.get("reply") or data.get("error") or "").strip()
print("      the answer:")
for line in reply.splitlines() or ["(nothing)"]:
    print("        %s" % line)
PY
else
    warn "no answer came back"
fi
rm -f "$REPLY_FILE" 2>/dev/null

# ------------------------------------------------- 6. who answered

say "6. Who answered"

HEALTH2=$(curl -s -m 20 "http://127.0.0.1:8787/health" -H "X-Auth-Token: $TOKEN" 2>/dev/null)
printf '%s' "$HEALTH2" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

backend = str(data.get("hermes") or "")
print("      %-18s %s" % ("the backend:", backend))
report = str(data.get("hermes_report") or "")
tail = str(data.get("hermes_tail") or "")
both = (report + " " + tail).lower()

if backend == "cli":
    print("      the agent answered - it has the tools, the web and the memory")
elif backend == "api-server":
    print("      the agent API answered")
else:
    print("      the agent did NOT answer - this was the plain fallback")

tools = [word for word in ("web_search", "web search", "browser_exec", "search_web",
                            "search", "browse") if word in both]
if tools:
    print("      the agent used these tools: %s" % ", ".join(sorted(set(tools))))
if "model is required" in both:
    print("      the agent had no model - that is the bug")
if "model not found" in both or "no such model" in both:
    print("      the model name was not accepted by the provider")
for line in (data.get("hermes_errors") or [])[-4:]:
    print("      %-18s %s" % ("why:", str(line)[:150]))
if report:
    print("      the agent said about itself:")
    print("        %s" % report[:600])
' 2>/dev/null

say "done"
info "if the backend says cli, the orb is now talking to your Hermes agent"
info "and the orb can look things up on the web, like Telegram does"
