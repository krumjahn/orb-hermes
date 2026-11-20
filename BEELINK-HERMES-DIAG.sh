#!/usr/bin/env bash
#
# BEELINK-HERMES-DIAG.sh - show the state of the Hermes agent, the messaging
# gateway and the settings on the Beelink.
#
# Run this ON the Beelink:
#
#     curl -fsSL http://192.168.1.10:8899/BEELINK-HERMES-DIAG.sh | bash
#
# This script only READS. It changes nothing, stops nothing and restarts
# nothing - it only tells you what is going on.
#
# The earlier version of this script did more: it repaired the settings and
# restarted the gateway. It did that badly, in two ways that cost a day:
#
#   * it looked for the gateway among the processes whose command line
#     contains the word "gateway" - and the Hermes CLI has a helper with
#     that word in it. The helper was killed, and the gateway with it.
#   * it restarted the gateway by copying the command line out of /proc and
#     running it again. The gateway is started as a "python -I -c ..."
#     line, and that line copied back is a syntax error, not a service.
#
# So the fixing moved to BEELINK-HERMES-RESTORE.sh, which restarts the
# gateway as the systemd service it is. This script only looks.
#
# Secrets are never printed.
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

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
bad()  { printf '\033[1;31m    %s\033[0m\n' "$*"; }

# Everything printed goes through here first, so a token never reaches the
# screen or the transcript. The "<" is left out of the last rule on purpose:
# a value that has already been masked keeps the marker it was given.
mask() {
    sed -E \
        -e 's/[0-9]{8,12}:[A-Za-z0-9_-]{25,}/<telegram-token>/g' \
        -e 's/(sk-[A-Za-z0-9_-]{12,})/<api-key>/g' \
        -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._-]{12,}/\1<token>/g' \
        -e 's/((api[_-]?key|token|secret|password)[[:space:]]*[:=][[:space:]]*)[^[:space:],<]{6,}/\1<set>/gi'
}

# ============================================================ 1. the settings

say "1. The settings file"

CFG=""
for CANDIDATE in "$HOME/.hermes/config.yaml" "$HOME/.hermes/config.yml"; do
    if [ -f "$CANDIDATE" ]; then
        CFG="$CANDIDATE"
        break
    fi
done

YAML_PY=""
for CANDIDATE in python3 "$HOME/.hermes/venv/bin/python" "$HOME/orb-hermes/venv/bin/python"; do
    if command -v "$CANDIDATE" >/dev/null 2>&1 && "$CANDIDATE" -c "import yaml" 2>/dev/null; then
        YAML_PY="$CANDIDATE"
        break
    fi
done

if [ -z "$CFG" ]; then
    bad "there is no config.yaml in ~/.hermes"
else
    info "$CFG"
    info "the model lines:"
    grep -nE "^[[:space:]]*model[[:space:]]*:" "$CFG" 2>/dev/null | sed 's/^/      /'
    info "the top of the file (the secrets are masked):"
    sed -n '1,12p' "$CFG" 2>/dev/null | mask | sed 's/^/      /'

    if [ -n "$YAML_PY" ]; then
        if "$YAML_PY" - "$CFG" <<'PY' 2>&1 | sed 's/^/      /'
import sys
import yaml
with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
print("the file parses")
if isinstance(data, dict):
    print("the keys are:", ", ".join(sorted(str(k) for k in data)[:25]))
    model = data.get("model")
    if isinstance(model, dict):
        print("model.default:", model.get("default"))
        print("model.provider:", model.get("provider"))
        print("model.base_url:", model.get("base_url"))
    else:
        print("model:", model)
PY
        then
            info "the settings are sound"
        else
            bad "the settings file does not parse"
            info "run BEELINK-HERMES-RESTORE.sh to put it right"
        fi
    else
        warn "no python with PyYAML was found here"
    fi

    info "the copies that are lying around:"
    ls -1t "$HOME/.hermes/" 2>/dev/null | grep -E "^config" | head -10 | sed 's/^/      /'
fi

if command -v hermes >/dev/null 2>&1; then
    info "hermes config check:"
    timeout 90 hermes config check 2>&1 | head -25 | mask | sed 's/^/      /'
fi

# ================================================================ 2. the agent

say "2. Does the agent answer"

if command -v hermes >/dev/null 2>&1; then
    info "this can take a while - the agent is slow to start"
    OUT=$(ask_agent "Reply with exactly: HELLO")
    if printf '%s\n' "$OUT" | python3 -c '
import sys
text = sys.stdin.read()
if any(m in text for m in ("model is required", "OpenRouter rejected",
                          "not retryable failed")):
    sys.exit(1)
sys.exit(0 if ("\u2624 Hermes" in text or "FINAL RESPONSE:" in text) else 1)
'; then
        info "the agent answers"
        printf '%s\n' "$OUT" | head -12 | mask | sed 's/^/      /'
    else
        warn "the agent does not answer"
        printf '%s\n' "$OUT" | head -25 | mask | sed 's/^/      /'
    fi
else
    warn "the hermes CLI is not on the PATH"
fi

# =========================================================== 3. the gateway

say "3. The messaging gateway (the Telegram bot)"

info "every hermes process, with its full command line:"
ps -eo pid,ppid,etimes,args 2>/dev/null | grep -iE "hermes" | grep -v grep | mask | sed 's/^/      /' | head -25

info "the user services:"
systemctl --user list-units --all --no-pager 2>/dev/null | grep -iE "hermes|gateway" | sed 's/^/      /' || true
systemctl --user list-unit-files --no-pager 2>/dev/null | grep -iE "hermes|gateway" | sed 's/^/      /' || true

# The gateway is found by its service, never by looking at command lines.
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
    warn "no gateway service was found"
else
    info "the gateway is the service: $GW_UNIT"
    info "  it is: $(systemctl --user is-enabled "$GW_UNIT" 2>/dev/null)"
    info "  it is running: $(systemctl --user is-active "$GW_UNIT" 2>/dev/null)"
    info "  what it runs:"
    systemctl --user show "$GW_UNIT" -p ExecStart --value 2>/dev/null | cut -c1-200 | sed 's/^/      /'
    info "  the status:"
    systemctl --user --no-pager status "$GW_UNIT" 2>/dev/null | head -12 | mask | sed 's/^/      /'
    info "  the last lines of its journal:"
    journalctl --user -u "$GW_UNIT" -n 25 --no-pager 2>/dev/null | mask | sed 's/^/      /' || true
fi

info "the other services:"
systemctl --user list-units --all --no-pager 2>/dev/null | grep -iE "orb|notes" | sed 's/^/      /' || true

# ============================================================== 4. the logs

say "4. The logs"

info "hermes logs:"
if command -v hermes >/dev/null 2>&1; then
    timeout 60 hermes logs 2>&1 | tail -30 | mask | sed 's/^/      /'
fi

info "the agent's own log folder:"
for LOG in "$HOME"/.hermes/logs/*.log "$HOME"/.hermes/logs/*; do
    [ -f "$LOG" ] || continue
    info "  $LOG"
    tail -12 "$LOG" 2>/dev/null | mask | sed 's/^/      /'
done

info "the journal of the user services:"
journalctl --user -n 40 --no-pager 2>/dev/null | grep -iE "hermes|gateway|telegram" | tail -25 | mask | sed 's/^/      /' || true

# ========================================================== 5. the network

say "5. Can it reach Telegram and the agent API"

# the token is used but never printed: only the status code comes back.
# 200 means the token works, 401 means Telegram does not accept it.
TG_TOKEN=""
if [ -n "$CFG" ]; then
    TG_TOKEN=$(grep -oE "[0-9]{8,12}:[A-Za-z0-9_-]{25,}" "$CFG" 2>/dev/null | head -1)
fi
if [ -z "$TG_TOKEN" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    TG_TOKEN="$TELEGRAM_BOT_TOKEN"
fi
if [ -n "$TG_TOKEN" ]; then
    CODE=$(curl -s -o /tmp/diag-tg.json -w '%{http_code}' -m 20 \
        "https://api.telegram.org/bot${TG_TOKEN}/getMe" 2>/dev/null || echo 000)
    info "telegram getMe: HTTP $CODE  (200 means the token is good)"
    [ "$CODE" = "200" ] && sed -n '1,3p' /tmp/diag-tg.json 2>/dev/null | mask | cut -c1-200 | sed 's/^/      /'
else
    warn "no telegram token was found in the settings or the environment"
fi

CODE=$(curl -s -o /tmp/diag-models.json -w '%{http_code}' -m 10 http://127.0.0.1:8642/v1/models 2>/dev/null || echo 000)
info "the agent API on 127.0.0.1:8642: HTTP $CODE"
[ "$CODE" = "200" ] && sed -n '1,4p' /tmp/diag-models.json 2>/dev/null | cut -c1-200 | sed 's/^/      /'

info "the models Ollama has:"
curl -s -m 10 http://127.0.0.1:11434/api/tags 2>/dev/null \
    | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for entry in (data.get("models") or [])[:15]:
    print("   ", entry.get("name"))
' 2>/dev/null || true

BRIDGE_PID=$(pgrep -f 'hermes_bridge.py' 2>/dev/null | head -1)
if [ -n "$BRIDGE_PID" ]; then
    info "the bridge is pid $BRIDGE_PID, running for $(ps -o etimes= -p "$BRIDGE_PID" 2>/dev/null | tr -d ' ') seconds"
else
    info "the bridge is not running"
fi

say "done"
info "this script only looked - it changed nothing"
info "to put the settings and the gateway right, run:"
info "    curl -fsSL http://192.168.1.10:8899/BEELINK-HERMES-RESTORE.sh | bash"
info "the settings are in:  hermes config edit"
info "the agent's own logs: hermes logs"
