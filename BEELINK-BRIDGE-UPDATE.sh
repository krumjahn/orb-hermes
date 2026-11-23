#!/usr/bin/env bash
#
# BEELINK-BRIDGE-UPDATE.sh - put the current bridge in every place it may
# live, give the agent a model, and prove it through the relay.
#
# Run this ON the Beelink (as the user that owns the Orb service):
#
#     curl -fsSL http://192.168.1.10:8899/BEELINK-BRIDGE-UPDATE.sh | bash
#
# Why this version is different from the last one:
#
#   * It finds the bridge the way it is *running* - the file in the running
#     process's command line, its working directory and its environment - and
#     replaces exactly that. The last version only looked under $HOME and
#     then restarted a service that may not have been the one running, so
#     the old bridge kept answering.
#
#   * It checks that the process really changed, and waits for the new build
#     to show up in /health, so "the script finished" no longer means
#     "something might have happened".
#
#   * The agent was answering "HTTP 400: model is required": the hermes CLI
#     had no model of its own, and it exits with 0 anyway, so the bridge read
#     the error report out loud. The bridge now spots that, tries the quiet
#     CLI mode instead, and falls back to Ollama.
#
set -uo pipefail

# The Hermes CLI has no "chat" subcommand.
#
#     hermes chat --query "..."   -> prints its own usage and exits
#
# The prompt goes in with "--query" (or "-z"), and the model with "--model".
# The old form was used everywhere, so the agent never ran and every check
# below said it was broken.
ask_agent() {
    local prompt="$1"
    shift
    local out=""
    local form
    for form in "--query" "-z"; do
        out=$(timeout "${AGENT_TIMEOUT:-120}" hermes "$form" "$prompt" "$@" </dev/null 2>&1)
        if ! printf '%s\n' "$out" | grep -qE "^usage: hermes|invalid choice|unrecognized arguments"; then
            printf '%s\n' "$out"
            return 0
        fi
    done
    printf '%s\n' "$out"
    return 1
}

MAC="http://192.168.1.10:8899"       # the file server (staging)
RELAY="http://192.168.1.10:8891"     # the bridge, the way the phone reaches it
TOKEN="YOUR_BRIDGE_TOKEN"
STAMP="$(date +%Y%m%d-%H%M%S)"
BRIDGE_DIR="$HOME/orb-hermes"
RUN_SCRIPT="$BRIDGE_DIR/run-bridge.sh"
EXPECTED_VERSION="2026-11-23a"
# where the process information lives. It is /proc on Linux; the override is
# only there so the logic can be tested without a Linux kernel.
PROC="${PROC:-/proc}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }

# ------------------------------------------- 1. the bridge that is running

say "1. The bridge that is running right now"

PIDS=$(pgrep -f 'hermes_bridge.py' | tr '\n' ' ')
if [ -z "$PIDS" ]; then
    warn "no hermes_bridge.py process is running"
else
    info "processes: $PIDS"
fi

RUNNING_FILE=""
RUNNING_CWD=""
RUNNING_CMD=""
RUNNING_ENV=""
OLD_PID=""

for PID in $PIDS; do
    CMD=$(tr '\0' ' ' < "$PROC/$PID/cmdline" 2>/dev/null)
    CWD=$(readlink "$PROC/$PID/cwd" 2>/dev/null)
    EXE=$(readlink "$PROC/$PID/exe" 2>/dev/null)
    info "  pid $PID  cwd=$CWD"
    info "    cmd: $CMD"
    info "    python: $EXE"

    # the file the process is actually running
    for ARG in $CMD; do
        case "$ARG" in
            */hermes_bridge.py)
                if [ -z "$RUNNING_FILE" ] && [ -f "$ARG" ]; then
                    RUNNING_FILE="$ARG"
                    RUNNING_CWD="$CWD"
                    RUNNING_CMD="$CMD"
                    # the whole environment is kept: the agent may need a
                    # setting that has nothing to do with the bridge
                    ENV_FILE="/tmp/bridge-env-$PID"
                    tr '\0' '\n' < "$PROC/$PID/environ" > "$ENV_FILE" 2>/dev/null
                    RUNNING_ENV=$(grep -E \
                        '^(HERMES|OLLAMA|MMX|WHISPER|BRIDGE|MODEL|LLM|OPENROUTER|ANTHROPIC)[A-Z_]*=' \
                        "$ENV_FILE" 2>/dev/null | tr '\n' ' ')
                    OLD_PID="$PID"
                    info "    the running file is: $RUNNING_FILE"
                    info "    its settings: ${RUNNING_ENV:-none}"
                fi
                break ;;
        esac
    done
done

if [ -z "$RUNNING_FILE" ]; then
    warn "could not work out which file the running bridge uses"
    warn "the service configuration below is the only clue left"
fi

say "2. The service, if there is one"

UNIT=""
if systemctl --user list-unit-files 2>/dev/null | grep -q "orb-hermes.service"; then
    UNIT="orb-hermes.service"
    systemctl --user show orb-hermes.service -p ExecStart -p WorkingDirectory -p Environment --no-pager 2>/dev/null \
        | sed 's/^/      /'
else
    info "there is no orb-hermes.service - the bridge is started by hand"
fi

# ------------------------------------------------- 3. install the new bridge

say "3. Installing the current bridge"

if ! curl -fsSL --max-time 60 -o /tmp/new-bridge.py "$MAC/hermes_bridge.py"; then
    warn "could not download the new bridge"
    exit 1
fi
if ! grep -q "clean_cli_output" /tmp/new-bridge.py; then
    warn "the downloaded bridge has no answer cleaner - refusing to install it"
    exit 1
fi
if ! grep -q "BRIDGE_VERSION" /tmp/new-bridge.py; then
    warn "the downloaded bridge has no version marker - refusing to install it"
    exit 1
fi
if ! grep -q "$EXPECTED_VERSION" /tmp/new-bridge.py; then
    FOUND_VERSION=$(grep -m1 'BRIDGE_VERSION[[:space:]]*=' /tmp/new-bridge.py 2>/dev/null \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[a-z]?' | head -1)
    warn "the downloaded bridge is version ${FOUND_VERSION:-unknown}, not $EXPECTED_VERSION - refusing to install it"
    exit 1
fi
# a half-downloaded file can still carry the right version marker, so the
# file has to parse as well
if ! python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' \
    /tmp/new-bridge.py 2>/dev/null; then
    warn "the downloaded bridge does not parse - refusing to install it"
    exit 1
fi
info "the new bridge is $(wc -c </tmp/new-bridge.py) bytes, version $EXPECTED_VERSION"

# every copy we can find, and the one that is running first
COPIES=""
if [ -n "$RUNNING_FILE" ]; then
    COPIES="$RUNNING_FILE"
fi
for ROOT in "$HOME" /opt /srv /usr/local; do
    [ -d "$ROOT" ] || continue
    FOUND=$(find "$ROOT" -maxdepth 5 -type f -name "hermes_bridge.py" 2>/dev/null)
    [ -n "$FOUND" ] && COPIES="$COPIES
$FOUND"
done

if [ -z "$(echo "$COPIES" | tr -d '[:space:]')" ]; then
    warn "no copy of the bridge found at all"
    exit 1
fi

UPDATED=0
for FILE in $(echo "$COPIES" | tr '\n' ' '); do
    if [ ! -f "$FILE" ]; then
        continue
    fi
    # The version has to match, not just the marker: an older bridge also
    # has a marker, and it must still be replaced.
    if grep -q "$EXPECTED_VERSION" "$FILE" 2>/dev/null; then
        info "already current: $FILE"
        continue
    fi
    OLD_VERSION=$(grep -m1 'BRIDGE_VERSION[[:space:]]*=' "$FILE" 2>/dev/null \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}[a-z]?' | head -1)
    cp "$FILE" "$FILE.bak-$STAMP" 2>/dev/null || true
    if cp /tmp/new-bridge.py "$FILE"; then
        info "updated: $FILE (was version ${OLD_VERSION:-unknown})"
        UPDATED=$((UPDATED + 1))
    else
        warn "could not update $FILE"
    fi
done
info "$UPDATED copy/copies updated"

# ------------------------------------------------------ 4. restart it, properly

say "4. Restarting the bridge"

# Only ONE bridge may run.
#
# When the service was started while a bridge was already running by hand,
# the two of them fought over the port: the service's bridge lost, systemd
# started it again, and every attempt loaded a fresh faster-whisper model
# before it found the port taken. The model that was actually answering the
# phone got less and less of the machine, and the wake word went from a
# second to five.
#
# So: the service is stopped, the old process is stopped, and then ONE of
# them starts - the service when it works, the script by hand when it does
# not.

if [ -n "$UNIT" ]; then
    info "stopping $UNIT"
    systemctl --user stop "$UNIT" 2>&1 | sed 's/^/      /'
    sleep 2
fi

if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    info "stopping the old process (pid $OLD_PID)"
    kill "$OLD_PID" 2>/dev/null
    sleep 3
    kill -9 "$OLD_PID" 2>/dev/null
fi

STARTED_BY=""
if [ -n "$UNIT" ]; then
    info "starting $UNIT"
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
fi

if [ -z "$STARTED_BY" ] && [ -n "$OLD_PID" ] && [ -n "$RUNNING_CMD" ]; then
    # the service cannot run it here, so it is started by hand - with the
    # same command, the same working directory and the same settings it had
    warn "starting it by hand instead"
    # put the old settings back - all of them, not just the bridge's own
    if [ -f "$ENV_FILE" ]; then
        while IFS= read -r PAIR; do
            if printf '%s' "$PAIR" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
                case "$PAIR" in
                    PATH=*)
                        # the old directories are added, not substituted:
                        # replacing the path could take the tools this
                        # script needs away
                        export PATH="$PATH:${PAIR#PATH=}"
                        ;;
                    *) export "$PAIR" 2>/dev/null || true ;;
                esac
            fi
        done < "$ENV_FILE"
    fi
    cd "$RUNNING_CWD" 2>/dev/null || cd "$HOME"
    nohup $RUNNING_CMD >> "$RUNNING_CWD/bridge.log" 2>&1 &
    STARTED_BY="the script"
    sleep 5
    info "started again from $RUNNING_CWD"
elif [ -z "$STARTED_BY" ]; then
    warn "nothing is running now - starting it by hand"
    for RUN in "$RUN_SCRIPT" "$HOME/orb-setup/beelink/run-bridge.sh"; do
        if [ -x "$RUN" ]; then
            nohup "$RUN" >> "$(dirname "$RUN")/bridge.log" 2>&1 &
            STARTED_BY="$RUN"
            info "started $RUN"
            break
        fi
    done
fi

info "the bridge is run by: ${STARTED_BY:-nothing}"
info "the bridge is now pid $(pgrep -f 'hermes_bridge.py' | head -1)"
sleep 5
pgrep -af 'hermes_bridge.py' 2>/dev/null | sed 's/^/      /' || true

# ------------------------------------------------- 5. did the new build answer

say "5. Is the new build answering?"

VERSION=""
for TRY in 1 2 3 4 5 6 7 8 9 10 11 12; do
    HEALTH=$(curl -s -m 20 "$RELAY/health" -H "X-Auth-Token: $TOKEN" 2>/dev/null)
    VERSION=$(printf '%s' "$HEALTH" | sed -nE 's/.*"bridge"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')
    if [ -n "$VERSION" ]; then
        break
    fi
    sleep 5
done
info "health: $HEALTH"
if [ "$VERSION" = "$EXPECTED_VERSION" ]; then
    info "the new bridge is running (version $VERSION)"
elif [ -n "$VERSION" ]; then
    warn "a bridge is running, but it is version $VERSION and not $EXPECTED_VERSION"
else
    warn "the health endpoint still does not report a version - the old bridge is running"
fi

# ------------------------------------------------------- 6. the agent's model

say "5b. The journal"

# The orb can answer questions about the journal because the bridge reads it
# from this machine and puts it in front of the model.
JOURNAL=""
for CAND in "$HOME/.hermes/profiles/memory/journal" "$HOME"/.hermes/profiles/*/memory/journal; do
    if [ -d "$CAND" ]; then
        JOURNAL="$CAND"
        break
    fi
done
if [ -n "$JOURNAL" ]; then
    info "the journal is at $JOURNAL"
    info "entries: $(ls -1 "$JOURNAL" 2>/dev/null | wc -l | tr -d ' ')"
    info "the newest: $(ls -t "$JOURNAL" 2>/dev/null | head -1)"
else
    warn "no journal folder found under $HOME/.hermes/profiles"
    info "the bridge also looks in $HOME/.hermes/profiles/*/memory/journal"
    info "to point it somewhere else, add this to $RUN_SCRIPT:"
    info "    export JOURNAL_DIR=/path/to/journal"
fi

say "6. The agent's model"

# The agent said "model is required", so the CLI had no model of its own.
# The models it used before are the ones known to work, and they are in the
# request dumps it leaves behind.
CANDIDATES=$(python3 - "$HOME/.hermes" <<'PY'
import os, re, sys

root = sys.argv[1]
found = []


def add(value):
    value = (value or "").strip().strip('"').strip("'")
    if not value or value.lower() in ("none", "null", "true", "false"):
        return
    # A model name never carries a space. A value with one is a sentence or a
    # fragment of the file it was read from - and writing one of those into
    # config.yaml puts a ": " in the value, which YAML reads as the start of
    # a mapping. The file then stops parsing and Hermes falls back to its
    # default settings, which have no model at all.
    if any(ch.isspace() for ch in value):
        return
    # A speech model is not an agent model. "base", "tiny", "small",
    # "medium" and "large" are the sizes of the whisper model, and
    # "whisper-1" is a speech-to-text model. One of them was pinned as the
    # agent's model, and the agent then had no model at all.
    if value.lower() in ("base", "tiny", "small", "medium", "large",
                         "whisper-1", "whisper-base", "whisper-large"):
        return
    if value not in found:
        found.append(value)


# 1. the models the agent actually used - these are known to work
sessions = os.path.join(root, "sessions")
if os.path.isdir(sessions):
    dumps = sorted(
        (os.path.join(sessions, n) for n in os.listdir(sessions) if n.endswith(".json")),
        key=lambda p: os.path.getmtime(p),
        reverse=True,
    )
    for path in dumps[:40]:
        try:
            text = open(path, encoding="utf-8", errors="replace").read()
        except Exception:
            continue
        for match in re.finditer(r'"model"\s*:\s*"([^"]+)"', text):
            add(match.group(1))

# 2. the settings file - only the agent's own model
#
# The old way of looking for a model in the settings read every "model:"
# key in the file, and the stt and tts sections have one of their own:
#
#     stt:
#       model: base
#     tts:
#       model: whisper-1
#
# So "base" - the size of the whisper model - was offered as the agent's
# model, and when it was pinned the agent had no model at all and answered
# "model is required" every time. Only "model.default" is the agent's.
for NAME in ("config.yaml", "config.yml"):
    path = os.path.join(root, NAME)
    if not os.path.isfile(path):
        continue
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
    except Exception:
        continue
    for index, line in enumerate(lines):
        if not re.match(r"^model[ \t]*:", line):
            continue
        for child in lines[index + 1:]:
            if not child.strip():
                continue
            if not child[:1].isspace():
                break
            match = re.match(r"^[ \t]+default[ \t]*:(.*)$", child)
            if match:
                value = match.group(1).strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                    value = value[1:-1]
                add(value)
        break

print("\n".join(found[:15]))
PY
)

if [ -z "$CANDIDATES" ]; then
    warn "no model found in the sessions or the configuration"
    info "the agent will keep failing - set one by hand, see the notes below"
else
    info "models found:"
    echo "$CANDIDATES" | sed 's/^/      /'
fi

say "6b. What the agent says about itself"

if command -v hermes >/dev/null 2>&1; then
    info "hermes --help:"
    timeout 30 hermes --help 2>&1 | head -25 | sed 's/^/      /'
    info "the model lines in the configuration:"
    for CFG in "$HOME/.hermes/config.yaml" "$HOME/.hermes/config.yml" \
               "$HOME/.hermes/config.json" "$HOME/.config/hermes/config.yaml"; do
        [ -f "$CFG" ] || continue
        info "  $CFG"
        grep -inE "model|provider|base_url" "$CFG" 2>/dev/null \
            | grep -viE "key|token|secret" | head -12 | sed 's/^/      /'
    done
    info "the environment the agent would use:"
    (env 2>/dev/null | grep -iE "^(HERMES|MODEL|LLM|OPENROUTER|ANTHROPIC)[A-Z_]*=" \
        | grep -viE "key|token|secret" | head -15 | sed 's/^/      /') || true
else
    warn "the hermes CLI is not on the PATH"
fi

# ------------------------------------------------ 6b. the agent's API server

say "6c. The agent's API server"

# The bridge is already set up for it: HERMES_BASE_URL points at
# 127.0.0.1:8642 and HERMES_API_KEY is set. The server itself is simply not
# running - and with it running, the agent answers with all its tools.
API="http://127.0.0.1:8642/v1"
CODE=$(curl -s -o /tmp/api-models.json -m 8 -w '%{http_code}' "$API/models" 2>/dev/null || echo 000)
info "the agent API $API/models -> HTTP $CODE"

if [ "$CODE" != "200" ]; then
    STARTED=0
    # a service that is there but stopped
    if command -v systemctl >/dev/null 2>&1; then
        for UNIT in $(systemctl --user list-unit-files 2>/dev/null \
            | grep -iE "hermes.*(api|serve|server)|^(api|serve)" | awk '{print $1}'); do
            info "starting $UNIT"
            systemctl --user start "$UNIT" 2>/dev/null && STARTED=1
        done
    fi
    # or one that is not a service at all
    if [ "$STARTED" = "0" ] && command -v hermes >/dev/null 2>&1; then
        for SUB in "api-server" "serve" "server" "api"; do
            if timeout 10 hermes "$SUB" --help >/dev/null 2>&1; then
                info "starting: hermes $SUB"
                nohup hermes "$SUB" >> "$HOME/hermes-api.log" 2>&1 &
                STARTED=1
                break
            fi
        done
    fi
    if [ "$STARTED" = "1" ]; then
        for TRY in 1 2 3 4 5 6 7 8 9 10 11 12; do
            sleep 5
            CODE=$(curl -s -o /tmp/api-models.json -m 8 -w '%{http_code}' "$API/models" 2>/dev/null || echo 000)
            if [ "$CODE" = "200" ]; then
                break
            fi
        done
    fi
fi

if [ "$CODE" = "200" ]; then
    info "the agent API is up - the orb will reach the agent itself"
    sed -n '1,4p' /tmp/api-models.json 2>/dev/null | cut -c1-200 | sed 's/^/      /'
else
    warn "the agent API is still not answering (HTTP $CODE)"
    info "the orb will keep using Ollama, which answers without tools"
fi

say "7. Trying each model until one answers"

info "this can take a few minutes - the agent is slow to start"
GOOD_MODEL=""
TRIED=0
if command -v hermes >/dev/null 2>&1; then
    for MODEL in $CANDIDATES; do
        TRIED=$((TRIED + 1))
        if [ "$TRIED" -gt 3 ]; then
            info "three is enough - the rest are left alone"
            break
        fi
        info "trying: $MODEL"
        OUT=$(ask_agent "Reply with exactly: HELLO" --model "$MODEL")
        # The emoji are compared by python, not by grep: a shell without a
        # UTF-8 locale would not match them.
        if printf '%s\n' "$OUT" | python3 -c '
import sys
text = sys.stdin.read()
if any(m in text for m in ("model is required", "OpenRouter rejected", "not retryable failed")):
    sys.exit(1)
sys.exit(0 if ("\u2624 Hermes" in text or "FINAL RESPONSE:" in text) else 1)
'; then
            info "  it answered - this model works"
            GOOD_MODEL="$MODEL"
            break
        fi
        if printf '%s\n' "$OUT" | grep -qE "model is required|OpenRouter rejected|not retryable failed"; then
            info "  the agent refused it"
            continue
        fi
        info "  no answer with this one"

        # The CLI may not take --model on the command line at all. If the
        # model belongs in the configuration, put it there - but in the
        # right place.
        for CFG in "$HOME/.hermes/config.yaml" "$HOME/.hermes/config.yml"; do
            [ -f "$CFG" ] || continue
            cp "$CFG" "$CFG.bak-$STAMP" 2>/dev/null || true
            # "model:" is usually the KEY of a block:
            #
            #     model:
            #       default: qwen3.8-27b-hermes
            #       provider: custom
            #
            # Writing the model onto that key line leaves YAML with a plain
            # value on line 1 and a nested block on line 2, which YAML
            # refuses to read - "mapping values are not allowed here". The
            # file then stops parsing, Hermes falls back to its default
            # settings (which have no model) and every request fails,
            # including the Telegram gateway.
            #
            # So the model goes into "default:" when "model:" is a block,
            # and stays the value of "model:" when "model:" is a plain
            # value. The key line never carries a value and a block at the
            # same time.
            python3 - "$CFG" "$MODEL" <<'PY'
import re, sys

path, model = sys.argv[1], sys.argv[2]


def indent_of(line):
    return len(line) - len(line.lstrip(" \t"))


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")

target = None
children = []
for index, line in enumerate(lines):
    # only a key at the left margin: the stt and tts sections have their
    # own "model:" keys
    match = re.match(r"^model[ \t]*:(.*)$", line)
    if not match:
        continue
    target = index
    probe = index + 1
    while probe < len(lines):
        child = lines[probe]
        if not child.strip():
            probe += 1
            continue
        if indent_of(child) <= 0:
            break
        children.append(probe)
        probe += 1
    break

safe = quote(model)
if target is None:
    while lines and not lines[-1].strip():
        lines.pop()
    lines.append("model:")
    lines.append("  default: " + safe)
    print("    made a model block")
elif children:
    lines[target] = "model:"
    written = False
    for child in children:
        match = re.match(r"^([ \t]+)default[ \t]*:(.*)$", lines[child])
        if match:
            lines[child] = match.group(1) + "default: " + safe
            written = True
            break
    if not written:
        lines.insert(target + 1, "  default: " + safe)
    print("    model.default: " + safe)
else:
    lines[target] = "model: " + safe
    print("    model: " + safe)

with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
PY
            # the file has to still be valid YAML - otherwise it is put back
            if python3 -c "import yaml" 2>/dev/null; then
                if ! python3 -c "
import sys, yaml
yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
" "$CFG" 2>/dev/null; then
                    warn "  the model broke $CFG - putting the old file back"
                    cp "$CFG.bak-$STAMP" "$CFG" 2>/dev/null || true
                    continue
                fi
                info "  the settings file still parses"
                # and the model has to be where Hermes reads it from: inside
                # "model.default" when "model:" is a block of settings
                if ! python3 -c "
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding='utf-8')) or {}
model = data.get('model')
if isinstance(model, dict):
    found = model.get('default')
else:
    found = model
sys.exit(0 if found == sys.argv[2] else 1)
" "$CFG" "$MODEL" 2>/dev/null; then
                    warn "  the model is not where Hermes looks for it - putting the old file back"
                    cp "$CFG.bak-$STAMP" "$CFG" 2>/dev/null || true
                    continue
                fi
                info "  the model is where Hermes looks for it"
            fi
            info "  wrote the model into $CFG, trying again"
            OUT=$(ask_agent "Reply with exactly: HELLO")
            if ! printf '%s\n' "$OUT" | grep -qE "model is required|OpenRouter rejected|not retryable failed" \
               && printf '%s\n' "$OUT" | python3 -c '
import sys
text = sys.stdin.read()
sys.exit(0 if ("\u2624 Hermes" in text or "FINAL RESPONSE:" in text) else 1)
'; then
                info "  it answered with the model in the configuration"
                GOOD_MODEL="$MODEL"
                break
            fi
            info "  still no answer"
        done
    done
else
    warn "the hermes CLI is not on the PATH - cannot test a model here"
fi

if [ -n "$GOOD_MODEL" ]; then
    if grep -q "^export HERMES_CLI_MODEL=" "$RUN_SCRIPT" 2>/dev/null; then
        sed -i "s|^export HERMES_CLI_MODEL=.*|export HERMES_CLI_MODEL=$GOOD_MODEL|" "$RUN_SCRIPT"
    else
        printf 'export HERMES_CLI_MODEL=%s\n' "$GOOD_MODEL" >> "$RUN_SCRIPT"
    fi
    info "pinned in run-bridge.sh: export HERMES_CLI_MODEL=$GOOD_MODEL"

    # and in the service itself, in case the service does not use that script
    if [ -n "$UNIT" ]; then
        DROPIN="$HOME/.config/systemd/user/$UNIT.d"
        mkdir -p "$DROPIN"
        {
            echo "[Service]"
            echo "Environment=HERMES_CLI_MODEL=$GOOD_MODEL"
        } > "$DROPIN/model.conf"
        systemctl --user daemon-reload 2>/dev/null
        systemctl --user restart "$UNIT" 2>/dev/null
        sleep 4
        info "pinned in the service too: $DROPIN/model.conf"
    fi
else
    warn "no model worked - the agent stays broken and the orb falls back to Ollama"
    info "to set one by hand, add this to $RUN_SCRIPT:"
    info "    export HERMES_CLI_MODEL=<the model id>"
    info "and check what the CLI offers with: hermes models"
fi

# A service that cannot start must not try for ever. Every attempt loads a
# whisper model before it finds the port taken, and that takes the machine
# away from the bridge that does work - the wake word went from a second to
# five while the service was restarting itself in a loop.
if [ -n "$UNIT" ]; then
    DROPIN="$HOME/.config/systemd/user/$UNIT.d"
    mkdir -p "$DROPIN"
    {
        echo "[Unit]"
        echo "StartLimitIntervalSec=120"
        echo "StartLimitBurst=3"
        echo "[Service]"
        echo "RestartSec=15"
    } > "$DROPIN/restart-limit.conf"
    systemctl --user daemon-reload 2>/dev/null
    info "the service may not retry for ever: $DROPIN/restart-limit.conf"
fi

say "8. Does the quiet mode answer?"

# The CLI has two shapes. "hermes --query" is the verbose agent mode:
# it prints its tool list and every API call, and it needs a model of its own.
# "hermes -z" is the quiet one - the same agent, just the transcript. The
# orb can answer from either, so it is worth knowing which one works.
if command -v hermes >/dev/null 2>&1; then
    QUIET=$(ask_agent "Reply with exactly: HELLO")
    if printf '%s\n' "$QUIET" | grep -q "HELLO" \
       && ! printf '%s\n' "$QUIET" | grep -qE "model is required|OpenRouter rejected"; then
        info "the quiet mode answers - the orb gets its answers even without a model"
    else
        warn "the quiet mode does not answer either - the agent really needs a model"
        printf '%s\n' "$QUIET" | tail -6 | sed 's/^/      /'
    fi
fi

# --------------------------------------------------- 9. the relay dialer

say "9. The relay dialer (it has a timeout of its own)"

# The dialer is the piece on this machine that talks to the Mac. It has a
# timeout of its own, and it has to be longer than the slowest answer - or
# it gives up while the agent is still thinking.
if curl -fsSL --max-time 60 -o /tmp/relay_dialer.py "$MAC/relay_dialer.py"; then
    DIALER_PIDS=$(pgrep -f 'relay_dialer.py' | tr '\n' ' ')
    if [ -z "$DIALER_PIDS" ]; then
        info "no relay_dialer.py is running here"
    else
        for PID in $DIALER_PIDS; do
            CMD=$(tr '\0' ' ' < "$PROC/$PID/cmdline" 2>/dev/null)
            CWD=$(readlink "$PROC/$PID/cwd" 2>/dev/null)
            DIALER_FILE=""
            for ARG in $CMD; do
                case "$ARG" in
                    */relay_dialer.py) DIALER_FILE="$ARG"; break ;;
                esac
            done
            if [ -z "$DIALER_FILE" ] || [ ! -f "$DIALER_FILE" ]; then
                continue
            fi
            info "the dialer runs from $DIALER_FILE (pid $PID)"
            DIALER_ENV=$(tr '\0' '\n' < "$PROC/$PID/environ" 2>/dev/null \
                | grep -E '^(RELAY|MAC|TOKEN|TUNNEL|BRIDGE)[A-Z_]*=' | tr '\n' ' ')
            if grep -q "BRIDGE_TIMEOUT = 420.0" "$DIALER_FILE" 2>/dev/null; then
                info "  it already has the long timeout"
                continue
            fi
            cp "$DIALER_FILE" "$DIALER_FILE.bak-$STAMP" 2>/dev/null || true
            if cp /tmp/relay_dialer.py "$DIALER_FILE"; then
                info "  updated"
                for PAIR in $DIALER_ENV; do
                    export "$PAIR"
                done
                cd "$CWD" 2>/dev/null || cd "$HOME"
                kill "$PID" 2>/dev/null
                sleep 2
                nohup $CMD >> "$CWD/dialer.log" 2>&1 &
                info "  restarted from $CWD"
            fi
        done
    fi
else
    warn "could not download the new dialer"
fi
sleep 3
pgrep -af 'relay_dialer.py' 2>/dev/null | sed 's/^/      /' || true

# --------------------------------------------------- 10. prove it, for real

say "10. The proof - through the relay, the way the phone reaches it"

START=$(date +%s)
ANSWER=$(curl -s -m 220 -X POST "$RELAY/chat" \
    -H 'Content-Type: application/json' \
    -H "X-Auth-Token: $TOKEN" \
    -d '{"text":"Reply with exactly: HELLO","session":"bridge-update-check"}' 2>&1)
END=$(date +%s)
info "took $((END-START))s"

python3 - "$ANSWER" <<'PY'
import json, sys

raw = sys.argv[1]
try:
    reply = json.loads(raw).get("reply", "")
except Exception:
    reply = raw

print("    reply:", repr(reply[:300]))
if "\u2624 Hermes" in reply or "AI Agent with Tool Calling" in reply \
        or "Resume this session" in reply or "FINAL RESPONSE:" in reply:
    print("    NOT CLEAN - the running bridge is still the old one")
    print("    check: systemctl --user show orb-hermes.service -p ExecStart")
elif reply.strip() == "HELLO":
    print("    CLEAN - the orb will only speak the answer")
elif "model is required" in reply:
    print("    THE AGENT IS STILL BROKEN - no model")
else:
    print("    the answer came through, and the chrome is gone")
PY

say "done"
info "logs: journalctl --user -u orb-hermes -n 30 --no-pager"
