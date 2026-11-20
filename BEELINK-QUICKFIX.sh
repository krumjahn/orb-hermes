#!/usr/bin/env bash
#
# BEELINK-QUICKFIX.sh - one shot at the Beelink.
#
# Run this ON the Beelink (as the user that owns the Orb services):
#
#     bash ~/BEELINK-QUICKFIX.sh
#
# It does the four things that are currently broken:
#
#   1. checks the MiniMax CLI and whether the bridge can use it
#   2. replaces the relay dialer, whose 15 s timeout cuts off every slow answer
#   3. replaces the bridge, so the wake-word matcher matches the phone's
#   4. looks at Ollama and unsticks the model if it is wedged
#
# Nothing is deleted: every file it replaces is copied to a .bak first.
#
set -uo pipefail

MAC="http://192.168.1.10:8899"
TOKEN="YOUR_BRIDGE_TOKEN"
DIALER_DIR="$HOME/orb-setup/beelink"
BRIDGE_DIR="$HOME/orb-hermes"
STAMP="$(date +%Y%m%d-%H%M%S)"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
fail() { printf '\033[1;31m    FAILED: %s\033[0m\n' "$*"; }

fetch() {
    # fetch <url> <destination> <marker that must be in the file>
    local url="$1" dest="$2" marker="$3"
    if ! curl -fsSL --max-time 60 -o "$dest.new" "$url"; then
        fail "could not download $url"
        rm -f "$dest.new"
        return 1
    fi
    if [ ! -s "$dest.new" ]; then
        fail "$dest.new is empty"
        rm -f "$dest.new"
        return 1
    fi
    if ! grep -q "$marker" "$dest.new"; then
        fail "$dest.new does not contain '$marker' - not installing it"
        rm -f "$dest.new"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------- 1. the CLI

say "1. MiniMax CLI"

if ! command -v mmx >/dev/null 2>&1; then
    info "mmx is not on PATH - the orb will keep using edge-tts for its voice"
    info "install it with:  npm install -g mmx-cli"
else
    info "mmx: $(command -v mmx)  $(mmx --version 2>/dev/null | head -1)"
    if mmx auth status >/tmp/mmx-auth.txt 2>&1; then
        info "authenticated:"
        sed 's/^/      /' /tmp/mmx-auth.txt
    else
        info "mmx is NOT authenticated - the orb will fall back to edge-tts"
        info "authenticate it with:  mmx auth login --api-key sk-xxxxx"
    fi

    # the bridge runs as this user, so the key has to be readable here
    if [ -f "$HOME/.mmx/credentials.json" ] || [ -f "$HOME/.mmx/config.json" ]; then
        info "key files live in $HOME/.mmx - the service user can read them"
    else
        info "no key files in $HOME/.mmx - run 'mmx auth login --api-key sk-xxxxx' as THIS user"
    fi

    # does the bridge's TTS path work?
    if mmx speech synthesize --text "Orb check." --out /tmp/mmx-orb-check.mp3 --quiet >/dev/null 2>&1; then
        info "speech test ok: $(wc -c </tmp/mmx-orb-check.mp3) bytes"
        info "once the bridge is restarted below, /health will report tts=mmx"
    else
        info "the speech test failed - check the key and the quota with 'mmx quota show'"
    fi
fi

# ------------------------------------------------------------- 2. the dialer

say "2. the relay dialer (the 15 second timeout)"

mkdir -p "$DIALER_DIR"
if fetch "$MAC/relay_dialer.py" "$DIALER_DIR/relay_dialer.py" "BRIDGE_TIMEOUT = 200.0"; then
    [ -f "$DIALER_DIR/relay_dialer.py" ] && cp "$DIALER_DIR/relay_dialer.py" "$DIALER_DIR/relay_dialer.py.bak-$STAMP"
    mv "$DIALER_DIR/relay_dialer.py.new" "$DIALER_DIR/relay_dialer.py"
    chmod +x "$DIALER_DIR/relay_dialer.py"
    info "installed, timeout line:"
    grep -n "BRIDGE_TIMEOUT" "$DIALER_DIR/relay_dialer.py" | sed 's/^/      /'
else
    info "keeping the old dialer"
fi

# restart it, the way it is actually run
if systemctl --user list-unit-files 2>/dev/null | grep -q "orb-relay-dialer"; then
    systemctl --user restart orb-relay-dialer.service 2>/dev/null
    sleep 3
    info "restarted orb-relay-dialer.service"
    systemctl --user --no-pager status orb-relay-dialer.service 2>/dev/null | head -8 | sed 's/^/      /'
else
    pkill -f 'relay_dialer.py' 2>/dev/null
    sleep 1
    nohup python3 "$DIALER_DIR/relay_dialer.py" 192.168.1.10 8890 "$TOKEN" 8787 \
        >> "$DIALER_DIR/dialer.log" 2>&1 &
    sleep 3
    info "started the dialer by hand"
    tail -5 "$DIALER_DIR/dialer.log" 2>/dev/null | sed 's/^/      /'
fi

# ------------------------------------------------------------- 3. the bridge

say "3. the bridge (the wake-word matcher)"

mkdir -p "$BRIDGE_DIR"
if fetch "$MAC/hermes_bridge.py" "$BRIDGE_DIR/hermes_bridge.py" "_sounds_like"; then
    [ -f "$BRIDGE_DIR/hermes_bridge.py" ] && cp "$BRIDGE_DIR/hermes_bridge.py" "$BRIDGE_DIR/hermes_bridge.py.bak-$STAMP"
    mv "$BRIDGE_DIR/hermes_bridge.py.new" "$BRIDGE_DIR/hermes_bridge.py"
    info "installed the new matcher"
else
    info "keeping the old bridge"
fi

if systemctl --user list-unit-files 2>/dev/null | grep -q "orb-hermes.service"; then
    systemctl --user restart orb-hermes.service 2>/dev/null
    sleep 4
    info "restarted orb-hermes.service"
    systemctl --user --no-pager status orb-hermes.service 2>/dev/null | head -10 | sed 's/^/      /'
else
    pkill -f 'hermes_bridge.py' 2>/dev/null
    sleep 1
    if [ -x "$BRIDGE_DIR/run-bridge.sh" ]; then
        nohup "$BRIDGE_DIR/run-bridge.sh" >> "$BRIDGE_DIR/bridge.log" 2>&1 &
        sleep 4
        info "started the bridge by hand"
        tail -8 "$BRIDGE_DIR/bridge.log" 2>/dev/null | sed 's/^/      /'
    else
        info "no run-bridge.sh - the bridge was not started"
    fi
fi

info "health:"
curl -s -m 20 http://127.0.0.1:8787/health -H "X-Auth-Token: $TOKEN" | sed 's/^/      /'
echo

# --------------------------------------------------------------- 4. the model

say "4. Ollama"

if command -v ollama >/dev/null 2>&1; then
    info "installed models:"
    ollama list 2>&1 | sed 's/^/      /'
    info "loaded right now:"
    ollama ps 2>&1 | sed 's/^/      /'
    info "memory:"
    free -h 2>/dev/null | head -3 | sed 's/^/      /'

    MODEL=$(ollama list 2>/dev/null | awk '/hermes/ {print $1; exit}')
    LOADED=$(ollama ps 2>/dev/null | awk '/hermes/ {print $1; exit}')

    if [ -n "$LOADED" ]; then
        # a model that is loaded but never answers is wedged - unloading it
        # makes the next request load it fresh
        info "unloading the loaded model $LOADED"
        ollama stop "$LOADED" 2>&1 | sed 's/^/      /'
        sleep 3
    fi

    if [ -n "$MODEL" ]; then
        info "loading $MODEL so it is warm (this takes a minute the first time)"
        timeout 300 ollama run "$MODEL" "Say OK" 2>&1 | tail -3 | sed 's/^/      /'
        info "loaded right now:"
        ollama ps 2>&1 | sed 's/^/      /'
    else
        info "no model with 'hermes' in its name - check 'ollama list' by hand"
    fi
else
    info "ollama is not on PATH - the bridge cannot talk to a model"
fi

# ------------------------------------------------------------- 5. the proof

say "5. the proof - a real answer through the relay"

START=$(date +%s)
OUT=$(curl -s -m 200 -X POST "$MAC/chat" \
    -H 'Content-Type: application/json' \
    -H "X-Auth-Token: $TOKEN" \
    -d '{"text":"Say OK"}' 2>&1)
END=$(date +%s)
info "took $((END-START))s"
info "$OUT"

case "$OUT" in
    *'"reply"'*) info "the bridge answered - the orb can talk again" ;;
    *)           info "no answer. If the dialer timeout is right and Ollama is loaded,"
                 info "then the model itself is stuck: 'ollama stop <model>' and try again." ;;
esac

say "done"
info "logs:  journalctl --user -u orb-hermes -n 30 --no-pager"
info "       journalctl --user -u orb-relay-dialer -n 30 --no-pager"
