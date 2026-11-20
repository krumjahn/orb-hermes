#!/usr/bin/env bash
#
# BEELINK-VOICE.sh - choose the voice the orb speaks with.
#
# Run this ON the Beelink (as the user that owns the Orb service):
#
#     curl -fsSL http://192.168.1.10:8899/BEELINK-VOICE.sh | bash -s -- English_SereneWoman
#
# With no argument it lists the female English voices and the one currently
# in use.
#
# The voice id comes from the MiniMax CLI:
#
#     mmx speech voices --output json --quiet
#
set -uo pipefail

TOKEN="YOUR_BRIDGE_TOKEN"
BRIDGE_DIR="$HOME/orb-hermes"
VOICE="${1:-}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }

list_voices() {
    mmx speech voices --output json --quiet 2>/dev/null | python3 -c '
import json, sys
try:
    voices = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
words = ("woman", "lady", "girl", "female", "host", "queen", "mother", "sister")
for voice in voices:
    if voice.startswith("English") and any(word in voice.lower() for word in words):
        print(voice)
' 2>/dev/null
}

if [ -z "$VOICE" ]; then
    say "the female English voices"
    CURRENT=$(grep '^export MMX_VOICE=' "$BRIDGE_DIR/run-bridge.sh" 2>/dev/null | cut -d= -f2-)
    info "in use now: ${CURRENT:-(the MiniMax default, English_expressive_narrator)}"
    echo
    list_voices | sed 's/^/    /'
    say "to pick one"
    info "curl -fsSL http://192.168.1.10:8899/BEELINK-VOICE.sh | bash -s -- English_SereneWoman"
    exit 0
fi

say "Checking the voice '$VOICE'"

if ! command -v mmx >/dev/null 2>&1; then
    warn "the MiniMax CLI is not on PATH - the orb will use edge-tts instead"
    exit 1
fi

if ! mmx speech voices --output json --quiet 2>/dev/null | grep -q "\"$VOICE\""; then
    warn "there is no voice called '$VOICE'"
    info "the female English voices are:"
    list_voices | sed 's/^/      /'
    exit 1
fi

TEST=$(mktemp /tmp/orb-voice-XXXXXX.mp3)
if ! mmx speech synthesize --text "The voice is set." --voice "$VOICE" --out "$TEST" --quiet >/dev/null 2>&1; then
    warn "the voice '$VOICE' could not be synthesized"
    rm -f "$TEST"
    exit 1
fi
info "it works ($(wc -c <"$TEST") bytes)"
rm -f "$TEST"

say "Setting it as the orb's voice"

if grep -q "^export MMX_VOICE=" "$BRIDGE_DIR/run-bridge.sh" 2>/dev/null; then
    sed -i "s/^export MMX_VOICE=.*/export MMX_VOICE=$VOICE/" "$BRIDGE_DIR/run-bridge.sh"
else
    printf 'export MMX_VOICE=%s\n' "$VOICE" >> "$BRIDGE_DIR/run-bridge.sh"
fi
info "run-bridge.sh now has: $(grep '^export MMX_VOICE=' "$BRIDGE_DIR/run-bridge.sh")"

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

say "The proof"
curl -s -m 180 -o /tmp/orb-voice-check.mp3 -w "    speech: HTTP %{http_code} | %{size_download} bytes\n" \
    -X POST http://127.0.0.1:8787/tts \
    -H 'Content-Type: application/json' \
    -H "X-Auth-Token: $TOKEN" \
    -d '{"text":"The orb is speaking in a new voice now."}'
info "the file is at /tmp/orb-voice-check.mp3 - play it with: afplay /tmp/orb-voice-check.mp3"

say "done"
