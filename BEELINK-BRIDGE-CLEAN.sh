#!/usr/bin/env bash
#
# BEELINK-BRIDGE-CLEAN.sh - put the bridge back to one process and one owner.
#
# Run this ON the Beelink:
#
#     curl -fsSL http://192.168.1.10:8899/BEELINK-BRIDGE-CLEAN.sh | bash
#
# What was wrong
# ---------------
# The bridge was started twice: once by the systemd service and once by
# hand. They fought over the port, the service's bridge lost, and systemd
# started it again - over and over.
#
# Every one of those attempts loaded a fresh faster-whisper model before it
# found the port taken. The model that was actually answering the phone got
# less and less of the machine, so the wake word went from a second to
# five, the phone's upload queue overflowed, and the orb stopped hearing
# anything.
#
# What this script does
# ----------------------
#   1. stops the service that is restarting itself in a loop,
#   2. stops every bridge process, including the whisper workers left
#      behind by the attempts that failed,
#   3. puts the current bridge in place, with the fix that takes the port
#      before it loads a model,
#   4. starts ONE bridge - by the service when the service works, by hand
#      when it does not,
#   5. proves it: the health endpoint, and how long a wake check takes.
#
# Secrets are never printed. The script can be run more than once.
#
set -uo pipefail

STAGE="${ORB_STAGE:-http://192.168.1.10:8899}"
BRIDGE_DIR="${ORB_BRIDGE_DIR:-$HOME/orb-hermes}"
BRIDGE_FILE="$BRIDGE_DIR/hermes_bridge.py"
RUN_SCRIPT="$BRIDGE_DIR/run-bridge.sh"
UNIT="orb-hermes.service"
EXPECTED_VERSION="2026-11-19f"
STAMP="$(date +%Y%m%d-%H%M%S)"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
bad()  { printf '\033[1;31m    %s\033[0m\n' "$*"; }

# ------------------------------------------------------- 1. what is running

say "1. What is running right now"

info "every bridge process:"
pgrep -af 'hermes_bridge.py' 2>/dev/null | sed 's/^/      /' || true

BRIDGE_COUNT=$(pgrep -f 'hermes_bridge.py' 2>/dev/null | wc -l | tr -d ' ')
WORKER_COUNT=$(pgrep -f 'hermes_bridge.py --whisper-worker' 2>/dev/null | wc -l | tr -d ' ')
info "bridge processes: $BRIDGE_COUNT   whisper workers: $WORKER_COUNT"
if [ "$BRIDGE_COUNT" -gt 2 ]; then
    warn "that is more than one bridge - they are fighting over the port"
fi

if systemctl --user is-enabled "$UNIT" >/dev/null 2>&1; then
    info "the service $UNIT is $(systemctl --user is-enabled "$UNIT" 2>/dev/null)"
    info "  it is $(systemctl --user is-active "$UNIT" 2>/dev/null)"
fi

# the token is needed for the health check - it is taken from the run
# script, and from the running process if that does not have it
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
    warn "no token was found - the health check will be skipped"
fi

# ------------------------------------------------- 2. stop the service

say "2. Stopping the service that is restarting itself"

systemctl --user stop "$UNIT" 2>&1 | sed 's/^/      /'
sleep 2
# it must not come back on its own while the work is going on
systemctl --user stop "$UNIT" 2>/dev/null
info "stopped"
systemctl --user --no-pager status "$UNIT" 2>/dev/null | head -6 | sed 's/^/      /' || true

# ------------------------------------------- 3. stop every bridge process

say "3. Stopping every bridge process"

for PID in $(pgrep -f 'hermes_bridge.py' 2>/dev/null); do
    info "stopping pid $PID"
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

# ------------------------------------------------- 4. put the new bridge in

say "4. Putting the current bridge in place"

if [ -f "$BRIDGE_FILE" ]; then
    cp -p "$BRIDGE_FILE" "$BRIDGE_FILE.bak-$STAMP" 2>/dev/null \
        && info "the old one is kept as $BRIDGE_FILE.bak-$STAMP"
fi

if curl -fsSL -m 60 "$STAGE/hermes_bridge.py" -o "$BRIDGE_FILE.new" 2>/dev/null; then
    if grep -q "$EXPECTED_VERSION" "$BRIDGE_FILE.new" \
        && python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' \
            "$BRIDGE_FILE.new" 2>/dev/null; then
        mv "$BRIDGE_FILE.new" "$BRIDGE_FILE"
        chmod +x "$BRIDGE_FILE" 2>/dev/null
        info "the new bridge is in place (version $EXPECTED_VERSION)"
    else
        rm -f "$BRIDGE_FILE.new" 2>/dev/null
        warn "the download did not carry the expected version - the old bridge is left"
    fi
else
    rm -f "$BRIDGE_FILE.new" 2>/dev/null
    warn "the bridge could not be downloaded - the old one is left"
fi

# ------------------------------------------- 5. start exactly one bridge

say "5. Starting one bridge"

# The service is the better owner: it starts the same script, and it brings
# the bridge back after a reboot. It is only left out of the way when it
# cannot start the bridge at all.
STARTED_BY=""
systemctl --user start "$UNIT" 2>&1 | sed 's/^/      /'
sleep 6
if systemctl --user is-active "$UNIT" >/dev/null 2>&1; then
    STARTED_BY="$UNIT"
    info "  the service owns the bridge"
    systemctl --user --no-pager status "$UNIT" 2>/dev/null | head -8 | sed 's/^/      /'
else
    warn "  the service did not come up"
    systemctl --user --no-pager status "$UNIT" 2>/dev/null | head -14 | sed 's/^/      /'
    # a service that cannot start is not left retrying for ever: every
    # attempt would load a whisper model and take the machine away from
    # the bridge that does work
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
    info "the last lines of the bridge log:"
    tail -20 "$BRIDGE_DIR/bridge.log" 2>/dev/null | sed 's/^/      /'
    exit 1
fi

info "the bridge is run by: $STARTED_BY"
pgrep -af 'hermes_bridge.py' 2>/dev/null | sed 's/^/      /' || true

# ------------------------------------------------------- 6. prove it

say "6. Does it answer"

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
        info "that is the expected version"
    else
        warn "that is not the expected version ($EXPECTED_VERSION)"
    fi
    printf '%s' "$HEALTH" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for key in ("ok", "hermes", "hermes_available", "hermes_error", "stt", "tts"):
    if key in data:
        print("  %-18s %s" % (key + ":", str(data[key])[:120]))
' 2>/dev/null
else
    bad "the bridge does not answer"
    tail -20 "$BRIDGE_DIR/bridge.log" 2>/dev/null | sed 's/^/      /'
    exit 1
fi

# a wake check has to be quick: when it takes five seconds the phone's
# upload queue overflows and the orb stops hearing
info "how long a wake check takes:"
python3 - <<'PY' 2>/dev/null || true
import math, struct, wave

path = "/tmp/bridge-clean-test.wav"
with wave.open(path, "wb") as handle:
    handle.setnchannels(1)
    handle.setsampwidth(2)
    handle.setframerate(16000)
    frames = bytearray()
    for index in range(16000):
        t = index / 16000.0
        value = int(2500 * math.sin(2 * math.pi * 170 * t))
        frames += struct.pack("<h", value)
    handle.writeframes(bytes(frames))
PY
for TRY in 1 2 3; do
    START=$(date +%s%N 2>/dev/null || date +%s)
    curl -s -m 60 -o /dev/null -X POST "http://127.0.0.1:8787/wake" \
        -H "X-Auth-Token: $TOKEN" -H "Content-Type: audio/wav" \
        --data-binary @/tmp/bridge-clean-test.wav 2>/dev/null
    END=$(date +%s%N 2>/dev/null || date +%s)
    if [ "${#START}" -gt 12 ] && [ "${#END}" -gt 12 ]; then
        info "  took $(( (END - START) / 1000000 )) ms"
    else
        info "  answered"
    fi
done
rm -f /tmp/bridge-clean-test.wav 2>/dev/null

# --------------------------------------------------- 7. the service again

say "7. The service"

if [ "$STARTED_BY" = "$UNIT" ]; then
    info "the service owns the bridge"
    systemctl --user enable "$UNIT" 2>/dev/null
    info "  it is enabled, so the bridge comes back after a reboot"
else
    info "the bridge was started by hand - the service is left stopped"
    info "so it cannot start a second one over the same port"
    if systemctl --user is-enabled "$UNIT" >/dev/null 2>&1; then
        systemctl --user disable "$UNIT" 2>/dev/null
        info "  and it is disabled, so it cannot restart itself in a loop"
    fi
fi

say "done"
info "the bridge is one process, run by one owner"
info "the orb should answer again - try it with your own voice"
