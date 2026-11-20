#!/usr/bin/env bash
#
# BEELINK-HERMES-BACKEND.sh - point the orb at the real Hermes.
#
# Run this ON the Beelink (as the user that owns the Orb service):
#
#     curl -fsSL http://192.168.1.10:8899/BEELINK-HERMES-BACKEND.sh | bash
#
# Why this is needed:
#
#   The bridge can talk to two different things on this machine.
#
#   * Ollama (127.0.0.1:11434) is only a model server. It answers from the
#     prompt alone - no memory, no tools, no access to this box. That is why
#     the orb cannot remember anything or read a file.
#
#   * The Hermes agent (its API server on 127.0.0.1:8642, or the hermes CLI)
#     is the one with the tools, the memory and the access to the machine.
#
#   The bridge used to try Ollama first, so Ollama always won and the orb
#   never reached the agent. This script finds the agent, proves it answers,
#   and makes the bridge prefer it.
#
set -uo pipefail

MAC="http://192.168.1.10:8899"
TOKEN="YOUR_BRIDGE_TOKEN"
BRIDGE_DIR="$HOME/orb-hermes"
API="http://127.0.0.1:8642/v1"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- 1. the facts

say "1. What is running on this machine?"

CODE=$(curl -s -o /tmp/hb-models.json -m 6 -w '%{http_code}' "$API/models" 2>/dev/null || echo 000)
info "agent API  $API/models -> HTTP $CODE"
MODELS=""
if [ "$CODE" = "200" ]; then
    sed 's/^/      /' /tmp/hb-models.json | head -6
    MODELS=$(python3 -c '
import json
try:
    data = json.load(open("/tmp/hb-models.json"))
except Exception:
    raise SystemExit
ids = [m.get("id") for m in data.get("data", []) if m.get("id")]
print(ids[0] if ids else "")
' 2>/dev/null)
fi

CLI=""
for BIN in hermes hermes-agent; do
    if command -v "$BIN" >/dev/null 2>&1; then
        info "CLI found: $BIN -> $(command -v "$BIN")"
        [ -z "$CLI" ] && CLI="$BIN"
    else
        info "CLI not found: $BIN"
    fi
done

info "services:"
(systemctl --user list-units --type=service --no-pager 2>/dev/null | grep -iE "hermes|ollama" | sed 's/^/      /') || true
(docker ps --format '{{.Names}}  {{.Image}}  {{.Status}}' 2>/dev/null | grep -iE "hermes|ollama" | sed 's/^/      /') || true

info "ollama models:"
(ollama list 2>/dev/null | head -8 | sed 's/^/      /') || true

info "the bridge's current configuration:"
grep -E "HERMES|OLLAMA" "$BRIDGE_DIR/run-bridge.sh" 2>/dev/null | sed 's/^/      /'

# ------------------------------------------------- 2. which one has the tools

say "2. Which backend actually has the memory and the tools?"

BACKEND=""
API_REPLY=""
for M in "$MODELS" "hermes-agent" ""; do
    BODY="{\"model\":\"${M:-hermes-agent}\",\"messages\":[{\"role\":\"user\",\"content\":\"List the names of the files in your home directory. Just the names.\"}],\"stream\":false}"
    API_REPLY=$(curl -s -m 120 -X POST "$API/chat/completions" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $TOKEN" \
        -d "$BODY" 2>&1)
    if echo "$API_REPLY" | grep -q '"choices"'; then
        BACKEND="api"
        info "the agent API answers (model: ${M:-hermes-agent}):"
        echo "$API_REPLY" | head -c 600 | sed 's/^/      /'
        echo
        break
    fi
done

if [ -z "$BACKEND" ] && [ -n "$CLI" ]; then
    info "trying the $CLI CLI (this can take a moment)..."
    CLI_REPLY=$(timeout 60 "$CLI" chat --query "List the names of the files in your home directory. Just the names." 2>&1 | head -c 600)
    if [ -n "$CLI_REPLY" ]; then
        BACKEND="cli"
        info "the $CLI CLI answers:"
        echo "$CLI_REPLY" | sed 's/^/      /'
    else
        warn "the $CLI CLI did not answer - it may be an interactive program"
    fi
fi

if [ -z "$BACKEND" ]; then
    warn "no Hermes agent answered - the orb will keep using Ollama"
    warn "that means no memory and no tools, until the agent is running"
    info "check whether the agent service is running (see the list above)"
    exit 1
fi

# ------------------------------------------------- 3. make the bridge prefer it

say "3. Making the bridge prefer the $BACKEND backend"

# the current bridge is needed for HERMES_PREFER to mean anything
if fetch_ok=0; then :; fi
if curl -fsSL --max-time 60 -o /tmp/hb-bridge.py "$MAC/hermes_bridge.py" 2>/dev/null \
   && grep -q "HERMES_PREFER" /tmp/hb-bridge.py; then
    cp "$BRIDGE_DIR/hermes_bridge.py" "$BRIDGE_DIR/hermes_bridge.py.bak" 2>/dev/null || true
    cp /tmp/hb-bridge.py "$BRIDGE_DIR/hermes_bridge.py"
    info "installed the current bridge (it knows about HERMES_PREFER)"
else
    warn "could not fetch the current bridge - keeping the one on disk"
fi

# write the preference into the service's environment
PREF="auto"
if [ "$BACKEND" = "cli" ]; then
    PREF="auto"   # auto falls through to the CLI when the API server is down
fi
if grep -q "^export HERMES_PREFER=" "$BRIDGE_DIR/run-bridge.sh" 2>/dev/null; then
    sed -i "s/^export HERMES_PREFER=.*/export HERMES_PREFER=$PREF/" "$BRIDGE_DIR/run-bridge.sh"
else
    printf 'export HERMES_PREFER=%s\n' "$PREF" >> "$BRIDGE_DIR/run-bridge.sh"
fi
info "run-bridge.sh now has: $(grep '^export HERMES_PREFER=' "$BRIDGE_DIR/run-bridge.sh")"

if systemctl --user list-unit-files 2>/dev/null | grep -q "orb-hermes.service"; then
    systemctl --user restart orb-hermes.service 2>/dev/null
    sleep 4
    info "restarted orb-hermes.service"
else
    pkill -f 'hermes_bridge.py' 2>/dev/null
    sleep 1
    nohup "$BRIDGE_DIR/run-bridge.sh" >> "$BRIDGE_DIR/bridge.log" 2>&1 &
    sleep 4
    info "started the bridge by hand"
fi

# ------------------------------------------------------------ 4. prove it

say "4. The proof"

START=$(date +%s)
ANSWER=$(curl -s -m 200 -X POST "$MAC/chat" \
    -H 'Content-Type: application/json' \
    -H "X-Auth-Token: $TOKEN" \
    -d '{"text":"List the names of the files in your home directory. Just the names.","session":"backend-check"}' 2>&1)
END=$(date +%s)
info "took $((END-START))s"
info "$ANSWER"

HINT=$(curl -s -m 20 "$MAC/health" -H "X-Auth-Token: $TOKEN" 2>/dev/null)
info "health: $HINT"
case "$HINT" in
    *'"hermes": "api-server"'*) info "the orb is now talking to the Hermes agent" ;;
    *'"hermes": "cli"'*)       info "the orb is now talking to the Hermes CLI" ;;
    *'"hermes": "ollama"'*)    warn "still Ollama - the agent did not take the question" ;;
    *)                        warn "could not tell which backend answered" ;;
esac

say "done"
info "logs: journalctl --user -u orb-hermes -n 30 --no-pager"
