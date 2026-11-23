#!/usr/bin/env bash
#
# BEELINK-API-SERVER.sh - turn on the Hermes API server and let the orb
# reach it.
#
# Run this ON the Beelink (as the user that owns the Orb service):
#
#     curl -fsSL http://192.168.68.57:8899/BEELINK-API-SERVER.sh | bash
#
# Why this is worth doing:
#
#   The orb asks the agent a question and waits for the answer. Until now
#   the bridge asked by running "hermes --query" - a fresh agent for every
#   single question. That agent loads its model and its tools before it
#   answers, so a question took between half a minute and nine minutes.
#   Nine minutes is not an answer, it is a fault.
#
#   The Hermes gateway can serve the very same agent over HTTP with the
#   model and the tools already loaded. That is the API server on
#   127.0.0.1:8642, and it is off by default. Turning it on is one setting
#   in ~/.hermes/.env and a restart of the gateway.
#
#   The key is generated here, written into ~/.hermes/.env (the gateway
#   reads it) and into the bridge's own environment (the bridge sends it).
#   It is never printed and never leaves this machine.
#
# What it does, in order:
#
#   1. find the gateway service (by its service, never by its command line)
#   2. turn the API server on in ~/.hermes/.env
#   3. restart the gateway and wait for 127.0.0.1:8642 to answer
#   4. give the bridge the key, so it can talk to the API server
#   5. put the current bridge in place and restart it
#   6. ask a real question through the relay and time the answer
#
set -uo pipefail

MAC="http://192.168.68.57:8899"       # the file server (staging)
RELAY="http://192.168.68.57:8891"     # the bridge, the way the phone reaches it
TOKEN="2dc762b6e106d6197604203744be222d"
API_BASE_URL="http://127.0.0.1:8642/v1"
API="$API_BASE_URL"
HERMES_DIR="$HOME/.hermes"
BRIDGE_DIR="$HOME/orb-hermes"
RUN_SCRIPT="$BRIDGE_DIR/run-bridge.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
# where the process information lives. It is /proc on Linux; the override is
# only there so the logic can be tested without a Linux kernel.
PROC="${PROC:-/proc}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m    %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. the gateway

say "1. The gateway service"

if ! command -v hermes >/dev/null 2>&1; then
    warn "the hermes CLI is not on the PATH - this script needs it"
    die "nothing was changed"
fi
info "hermes: $(command -v hermes)"

# The gateway is found by its service, never by looking at command lines.
#
# An earlier version of this script searched for a process whose command
# line contained the word "gateway" - and the Hermes CLI has a helper with
# that word in it. The helper was killed, and the gateway with it.
GW_UNIT=""
for U in $(systemctl --user list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}'); do
    case "$U" in
        hermes*gateway*.service) GW_UNIT="$U"; break ;;
    esac
done
if [ -z "$GW_UNIT" ]; then
    for U in $(systemctl --user list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}'); do
        DESC=$(systemctl --user show "$U" -p Description --value 2>/dev/null)
        case "$DESC" in
            *[Gg]ateway*) GW_UNIT="$U"; break ;;
        esac
    done
fi

if [ -z "$GW_UNIT" ]; then
    warn "no gateway service was found - the API server has to be started by hand"
    warn "add API_SERVER_ENABLED=true and API_SERVER_KEY=<something long> to ~/.hermes/.env"
    warn "and run 'hermes gateway run' as a service"
    die "nothing was changed"
fi
info "the gateway is the service: $GW_UNIT"
info "  it is running: $(systemctl --user is-active "$GW_UNIT" 2>/dev/null)"

# --------------------------------------------------- 2. the API server setting

say "2. Turning the API server on"

# The key is taken from the place the gateway already has one, so the
# gateway and the bridge cannot end up with two different keys. Only when
# there is none anywhere a new one is made.
API_KEY=""
GW_ENV=$(systemctl --user show "$GW_UNIT" -p Environment --value 2>/dev/null)
case "$GW_ENV" in
    *API_SERVER_KEY=*)
        API_KEY="${GW_ENV#*API_SERVER_KEY=}"
        API_KEY="${API_KEY%% *}"
        API_KEY="${API_KEY%\"}"; API_KEY="${API_KEY#\"}"
        ;;
esac

# the service may read its settings from a file instead
ENV_FILES=""
for EF in $(systemctl --user show "$GW_UNIT" -p EnvironmentFiles --value 2>/dev/null | tr ' ' '\n' | sed 's/^-//'); do
    [ -f "$EF" ] || continue
    ENV_FILES="$ENV_FILES $EF"
    if [ -z "$API_KEY" ]; then
        API_KEY=$(grep -oE '^[[:space:]]*(export[[:space:]]+)?API_SERVER_KEY=.*' "$EF" 2>/dev/null \
            | head -1 | sed -E 's/^[^=]*=//' | tr -d '"'"'"'' | head -1)
    fi
done

for EF in $ENV_FILES; do
    info "the service reads its settings from $EF"
done

if [ -z "$API_KEY" ] && [ -f "$HERMES_DIR/.env" ]; then
    API_KEY=$(grep -oE '^[[:space:]]*(export[[:space:]]+)?API_SERVER_KEY=.*' "$HERMES_DIR/.env" 2>/dev/null \
        | head -1 | sed -E 's/^[^=]*=//' | tr -d '"'"'"'' | head -1)
fi
if [ -z "$API_KEY" ]; then
    API_KEY=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi
[ -n "$API_KEY" ] || die "no key could be made"
info "the key is ready (it is not printed)"

# The settings go into ~/.hermes/.env and into every profile that has one
# of its own, because the gateway may be serving a profile rather than the
# default one.
write_settings() {
    python3 - "$1" "$API_KEY" "$API_BASE_URL" <<'PY'
import sys

path, key, base_url = sys.argv[1], sys.argv[2], sys.argv[3]

wanted = {
    "API_SERVER_ENABLED": "true",
    "API_SERVER_KEY": key,
    "API_SERVER_HOST": "127.0.0.1",
    "API_SERVER_PORT": "8642",
}

try:
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
except FileNotFoundError:
    lines = []

out = []
seen = set()
for line in lines:
    name = line.split("=", 1)[0].strip()
    if name.startswith("export "):
        name = name[len("export "):].strip()
    if name in wanted:
        if name not in seen:
            out.append(f"{name}={wanted[name]}")
            seen.add(name)
        continue
    out.append(line)

for name, value in wanted.items():
    if name not in seen:
        out.append(f"{name}={value}")

with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(out).rstrip("\n") + "\n")
print(f"    {path}: API_SERVER_ENABLED, API_SERVER_KEY, API_SERVER_HOST, API_SERVER_PORT")
PY
}

mkdir -p "$HERMES_DIR"
[ -f "$HERMES_DIR/.env" ] || : > "$HERMES_DIR/.env"
cp "$HERMES_DIR/.env" "$HERMES_DIR/.env.bak-$STAMP" 2>/dev/null || true
write_settings "$HERMES_DIR/.env"

for PROFILE_DIR in "$HERMES_DIR"/profiles/*/; do
    [ -d "$PROFILE_DIR" ] || continue
    [ -f "$PROFILE_DIR/.env" ] || continue
    cp "$PROFILE_DIR/.env" "$PROFILE_DIR/.env.bak-$STAMP" 2>/dev/null || true
    write_settings "${PROFILE_DIR%/}/.env"
done

# a service that reads its settings from a file needs the key there too
for EF in $ENV_FILES; do
    if grep -q 'API_SERVER_KEY' "$EF" 2>/dev/null; then
        cp "$EF" "$EF.bak-$STAMP" 2>/dev/null || true
        python3 - "$EF" "$API_KEY" <<'PY'
import sys
path, key = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
out = []
for line in lines:
    name = line.split("=", 1)[0].strip()
    if name.startswith("export "):
        name = name[len("export "):].strip()
    if name == "API_SERVER_KEY":
        out.append(f"API_SERVER_KEY={key}")
        continue
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out))
print(f"    {path}: the key was replaced")
PY
    fi
done

# ------------------------------------------- 3. restart the gateway and wait

say "3. Restarting the gateway"

systemctl --user restart "$GW_UNIT" 2>&1 | sed 's/^/      /'
sleep 4

# The gateway says where it is listening, and that is better than assuming:
# the port can be set in the settings, and a gateway that serves several
# profiles may have picked another one.
LISTEN=$(journalctl --user -u "$GW_UNIT" -n 80 --no-pager 2>/dev/null \
    | grep -oE 'API server listening on http://[0-9.]+:[0-9]+' | tail -1 | awk '{print $NF}')
if [ -n "$LISTEN" ]; then
    case "$LISTEN" in
        */v1) API_BASE_URL="$LISTEN" ;;
        *)    API_BASE_URL="$LISTEN/v1" ;;
    esac
    API="$API_BASE_URL"
    info "the gateway says it is listening on $LISTEN"
else
    info "the gateway did not say where it listens - using $API_BASE_URL"
fi

info "waiting for the API server on $API_BASE_URL"

API_UP=0
CODE=000
for _ in $(seq 1 60); do
    CODE=$(curl -s -o /tmp/api-models.json -m 5 -w '%{http_code}' \
        -H "Authorization: Bearer $API_KEY" "$API/models" 2>/dev/null || echo 000)
    if [ "$CODE" = "200" ]; then
        API_UP=1
        break
    fi
    sleep 2
done

if [ "$API_UP" != "1" ]; then
    warn "the API server did not answer on 8642 (last status: ${CODE:-none})"
    info "what the gateway says:"
    journalctl --user -u "$GW_UNIT" -n 25 --no-pager 2>/dev/null \
        | sed -E 's/(sk-[A-Za-z0-9_-]{12,})/<api-key>/g' | tail -15 | sed 's/^/      /' || true
    warn "the API server is optional: the orb still works through the CLI, just slowly"
    exit 1
fi

info "the API server answers"
python3 - <<'PY'
import json
try:
    data = json.load(open("/tmp/api-models.json"))
except Exception:
    print("    (the model list could not be read)")
else:
    names = [m.get("id") for m in (data.get("data") or []) if isinstance(m, dict)]
    print("    it serves:", ", ".join(n for n in names if n) or "(none named)")
PY

# --------------------------------------------------- 4. the bridge gets the key

say "4. Giving the bridge the key"

# The bridge sends the key with every request to the API server. It has to
# find it in its own environment, so the key goes into the three places a
# bridge can be started from: the run script, the service's drop-in, and
# this shell - the bridge started below inherits it.
export HERMES_API_KEY="$API_KEY"
export HERMES_BASE_URL="$API_BASE_URL"

set_env_line() {
    # set_env_line <file> <NAME> <value>
    local file="$1" name="$2" value="$3"
    [ -f "$file" ] || return 0
    if grep -qE "^[[:space:]]*(export[[:space:]]+)?${name}=" "$file" 2>/dev/null; then
        python3 - "$file" "$name" "$value" <<'PY'
import re, sys
path, name, value = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path, encoding="utf-8").read().split("\n")
out = []
for line in lines:
    head = line.split("=", 1)[0].strip()
    if head.startswith("export "):
        head = head[len("export "):].strip()
    if head == name:
        out.append(f"export {name}={value}")
        continue
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out))
PY
    else
        printf 'export %s=%s\n' "$name" "$value" >> "$file"
    fi
}

if [ -f "$RUN_SCRIPT" ]; then
    cp "$RUN_SCRIPT" "$RUN_SCRIPT.bak-$STAMP" 2>/dev/null || true
    set_env_line "$RUN_SCRIPT" "HERMES_API_KEY" "$API_KEY"
    set_env_line "$RUN_SCRIPT" "HERMES_BASE_URL" "$API_BASE_URL"
    info "the key is in $RUN_SCRIPT"
else
    info "$RUN_SCRIPT does not exist - the service is probably started directly"
fi

UNIT=""
if systemctl --user list-unit-files 2>/dev/null | grep -q "orb-hermes.service"; then
    UNIT="orb-hermes.service"
    DROPIN="$HOME/.config/systemd/user/$UNIT.d"
    mkdir -p "$DROPIN"
    {
        echo "[Service]"
        echo "Environment=HERMES_API_KEY=$API_KEY"
        echo "Environment=HERMES_BASE_URL=$API_BASE_URL"
    } > "$DROPIN/apiserver.conf"
    systemctl --user daemon-reload 2>/dev/null
    info "the key is in the service's drop-in"
else
    info "there is no orb-hermes.service - the bridge is started by hand"
fi

# ---------------------------------------------- 5. the current bridge, in place

say "5. The current bridge"

if curl -fsSL --max-time 60 -o /tmp/new-bridge.py "$MAC/hermes_bridge.py"; then
    if grep -q "BRIDGE_VERSION" /tmp/new-bridge.py \
        && python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' \
            /tmp/new-bridge.py 2>/dev/null; then
        # the file the bridge is actually running from, first
        RUNNING_FILE=""
        for PID in $(pgrep -f 'hermes_bridge.py' 2>/dev/null); do
            CMD=$(tr '\0' ' ' < "$PROC/$PID/cmdline" 2>/dev/null)
            for ARG in $CMD; do
                case "$ARG" in
                    */hermes_bridge.py)
                        if [ -f "$ARG" ]; then RUNNING_FILE="$ARG"; fi
                        break ;;
                esac
            done
            [ -n "$RUNNING_FILE" ] && break
        done
        [ -n "$RUNNING_FILE" ] || RUNNING_FILE="$BRIDGE_DIR/hermes_bridge.py"
        if [ -f "$RUNNING_FILE" ]; then
            cp "$RUNNING_FILE" "$RUNNING_FILE.bak-$STAMP" 2>/dev/null || true
            if cp /tmp/new-bridge.py "$RUNNING_FILE"; then
                info "the bridge was replaced: $RUNNING_FILE"
            else
                warn "the bridge could not be replaced"
            fi
        else
            warn "no copy of the bridge was found"
        fi
    else
        warn "the downloaded bridge did not look right - not installing it"
    fi
else
    warn "the bridge could not be downloaded"
fi

# ------------------------------------------------------- 6. restart and prove

say "6. Restarting the bridge"

if [ -n "$UNIT" ]; then
    systemctl --user restart "$UNIT" 2>&1 | sed 's/^/      /'
    sleep 6
    if systemctl --user is-active "$UNIT" >/dev/null 2>&1; then
        info "the service owns the bridge"
    else
        warn "the service did not come up - starting the bridge by hand"
        systemctl --user stop "$UNIT" 2>/dev/null
        if [ -x "$RUN_SCRIPT" ]; then
            nohup "$RUN_SCRIPT" >> "$BRIDGE_DIR/bridge.log" 2>&1 &
            info "started it from $RUN_SCRIPT"
        fi
    fi
else
    PIDS=$(pgrep -f 'hermes_bridge.py' | tr '\n' ' ')
    for PID in $PIDS; do
        info "stopping the old bridge (pid $PID)"
        kill "$PID" 2>/dev/null
    done
    sleep 3
    if [ -x "$RUN_SCRIPT" ]; then
        nohup "$RUN_SCRIPT" >> "$BRIDGE_DIR/bridge.log" 2>&1 &
        info "started it from $RUN_SCRIPT"
    else
        warn "$RUN_SCRIPT is not executable - start the bridge by hand"
    fi
fi
sleep 4

say "7. The proof - a real question, through the relay, and how long it takes"

START=$(date +%s)
ANSWER=$(curl -s -m 300 -X POST "$RELAY/chat" \
    -H 'Content-Type: application/json' \
    -H "X-Auth-Token: $TOKEN" \
    -d '{"text":"Reply with exactly: HELLO","session":"api-server-check"}' 2>&1)
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
PY

say "8. What the bridge thinks"

curl -s -m 20 "$RELAY/health" 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("    (the health endpoint did not answer)")
    raise SystemExit(0)
api = data.get("hermes_api") or {}
print("    the backend it used :", data.get("hermes"))
print("    the API server      :", api.get("url"), "reachable:", api.get("reachable"))
print("    the models it serves:", ", ".join(api.get("models") or []) or "(none)")
print("    the key is set      :", api.get("key_set"))
' 2>/dev/null || true

say "done"
info "logs: journalctl --user -u orb-hermes -n 30 --no-pager"
