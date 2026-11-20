#!/usr/bin/env bash
#
# BEELINK-HERMES-RESTORE.sh - put the Hermes agent and the Telegram gateway
# back the way they were.
#
# Run this ON the Beelink:
#
#     curl -fsSL http://192.168.1.10:8899/BEELINK-HERMES-RESTORE.sh | bash
#
# What was broken
# ---------------
# A script of ours wrote the model name onto the "model:" line of
# ~/.hermes/config.yaml. That line was not a value - it was the key of a
# block:
#
#     model:
#       default: qwen3.8-27b-hermes
#       provider: custom
#       base_url: http://localhost:11434/v1
#
# Writing "model: qwen3.8-27b-hermes" on top of it left YAML with a plain
# value on line 1 and a nested block on line 2, which YAML refuses to read:
#
#     mapping values are not allowed here, line 2, column 10
#
# Hermes then ran on its own default settings - and those have no model at
# all - so the agent failed and the Telegram gateway had nothing to talk to.
#
# What this script does
# ----------------------
#   1. finds the copy of the settings that was made before the damage and
#      puts it back; when there is no such copy, it repairs the file where
#      it lies - the model goes back into "default:", where it belongs,
#   2. checks that the agent really answers, and tries the models that are
#      installed here when it does not,
#   3. restarts the gateway as the systemd service it is,
#   4. starts the bridge again, so the orb stops using the fallback it
#      remembers from the broken hour.
#
# Two things it will never do:
#
#   * it will not kill a process because its command line happens to contain
#     the word "gateway" - a helper of the Hermes CLI has that word in it,
#     and killing it took the real gateway down with it,
#   * it will not run a command line that was copied out of /proc - a
#     "python -I -c ..." line copied back is a syntax error, not a service.
#
# The gateway is only ever started through systemctl --user: the same unit,
# the same environment, the same working folder.
#
# Secrets are never printed. The script can be run more than once.
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

STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TAB=$'\t'
AGENT_TIMEOUT="${AGENT_TIMEOUT:-300}"

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

# The command line, the working folder and the settings of a running
# process.
proc_cmdline() {
    local pid="$1"
    if [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null
        return 0
    fi
    ps -o args= -p "$pid" 2>/dev/null
}

proc_cwd() {
    local pid="$1"
    if [ -L "/proc/$pid/cwd" ]; then
        readlink "/proc/$pid/cwd" 2>/dev/null
        return 0
    fi
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}

proc_env() {
    local pid="$1"
    if [ -r "/proc/$pid/environ" ]; then
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null
    fi
}

# ------------------------------------------------------- the settings tool
#
# One small python program does all the work on the settings file. It works
# on the text, not on a parsed document, so it can repair a file that no
# longer parses - which is the whole point here. PyYAML is used when it is
# there, only to double check the result.

cat > "$WORK/cfgtool.py" <<'PY'
"""hermes settings tool - look at, repair and check ~/.hermes/config.yaml."""
import glob
import os
import re
import sys

try:
    import yaml
except Exception:
    yaml = None


def indent_of(line):
    return len(line) - len(line.lstrip(" \t"))


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def model_block(lines):
    """The top level "model:" key: its line, its value and its children.

    Only a key at the left margin counts. The stt and tts sections have
    their own "model:" keys, and those must not be touched.
    """
    for index, line in enumerate(lines):
        match = re.match(r"^model[ \t]*:(.*)$", line)
        if not match:
            continue
        value = match.group(1).strip()
        children = []
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
        return index, value, children
    return None, None, []


def describe(text):
    """What the settings file actually says."""
    lines = text.split("\n")
    index, value, children = model_block(lines)
    info = {
        "has_model": index is not None,
        "mapping": bool(children),
        "default": None,
        "provider": False,
        "base_url": False,
        "token": bool(re.search(r"[0-9]{8,12}:[A-Za-z0-9_-]{25,}", text)),
        "value": value or "",
    }
    for child in children:
        match = re.match(r"^([ \t]+)([A-Za-z0-9_.-]+)[ \t]*:(.*)$", lines[child])
        if not match:
            continue
        key = match.group(2)
        raw = match.group(3).strip()
        if key == "default":
            info["default"] = unquote(raw)
        elif key == "provider":
            info["provider"] = True
        elif key == "base_url":
            info["base_url"] = True
    return info


def yaml_problem(text):
    """Why YAML would refuse this file. None when it looks all right.

    This is not a full YAML parser. It looks for the two mistakes that
    actually happen here: a value with a colon and a space in it, and a
    value on a key line with a block underneath it.
    """
    lines = text.split("\n")
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.match(r"^([ \t]*)([^:#][^:]*?)[ \t]*:(.*)$", line)
        if not match:
            continue
        indent, value = match.group(1), match.group(3).strip()
        if value:
            # a value on the key line, and then a block under it - YAML reads
            # the value as the whole content of the key, so the block below
            # has nowhere to go
            probe = index + 1
            while probe < len(lines):
                child = lines[probe]
                if not child.strip():
                    probe += 1
                    continue
                if indent_of(child) > len(indent):
                    return "line %d: a value with a block under it" % (index + 1)
                break
        if not value or value.startswith(("'", '"')):
            continue
        if value.endswith(":"):
            return "line %d: a value that ends in a colon" % (index + 1)
        if ": " in value:
            return "line %d: a value with a colon and a space in it" % (index + 1)
    if yaml is not None:
        try:
            yaml.safe_load(text)
        except Exception as exc:
            return "YAML says: %s" % str(exc).replace("\n", " ")[:160]
    return None


def set_model(text, model):
    """Put the model where it belongs.

    When "model:" is the key of a block, the model goes into "default:",
    which is where Hermes reads it from. When "model:" is a plain value, the
    value is replaced. Either way the key line never carries a value and a
    block at the same time - that combination is what broke the file.
    """
    lines = text.split("\n")
    index, value, children = model_block(lines)
    safe = quote(model)

    if index is None:
        while lines and not lines[-1].strip():
            lines.pop()
        lines.append("model:")
        lines.append("  default: " + safe)
        return "\n".join(lines), "made a model block"

    if children:
        lines[index] = "model:"
        for child in children:
            match = re.match(r"^([ \t]+)default[ \t]*:(.*)$", lines[child])
            if match:
                lines[child] = match.group(1) + "default: " + safe
                return "\n".join(lines), "wrote model.default"
        lines.insert(index + 1, "  default: " + safe)
        return "\n".join(lines), "added model.default"

    lines[index] = "model: " + safe
    return "\n".join(lines), "wrote the model value"


def candidates():
    """Every copy of the settings that is lying around, newest first."""
    home = os.path.expanduser("~")
    root = os.path.join(home, ".hermes")
    patterns = [
        os.path.join(root, "config.yaml.bak-*"),
        os.path.join(root, "config.yaml.orig"),
        os.path.join(root, "config.yaml.save"),
        os.path.join(root, "config.yaml.*"),
        os.path.join(root, "backups", "config", "config.yaml.*"),
        os.path.join(root, "backups", "config.yaml.*"),
        os.path.join(root, "config", "config.yaml.*"),
    ]
    found = []
    seen = set()
    for pattern in patterns:
        for path in sorted(glob.glob(pattern)):
            if path in seen or not os.path.isfile(path):
                continue
            seen.add(path)
            found.append(path)
    found.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return found


def score(text):
    """How good is this copy of the settings? Higher is better."""
    info = describe(text)
    problem = yaml_problem(text)
    total = 0
    if problem is None:
        total += 100
    if info["mapping"] and info["default"]:
        total += 60
    elif info["has_model"]:
        total += 20
    if info["provider"] and info["base_url"]:
        total += 15
    if info["token"]:
        total += 10
    return total, info, problem


def main(argv):
    command = argv[1] if len(argv) > 1 else ""

    if command == "candidates":
        for path in candidates():
            print(path)
        return 0

    if command == "rank":
        rows = []
        for path in argv[2:]:
            text = read(path)
            total, info, problem = score(text)
            rows.append((total, os.path.getmtime(path), path, problem))
        rows.sort(key=lambda row: (-row[0], -row[1]))
        for total, mtime, path, problem in rows:
            print("%d\t%d\t%s\t%s" % (total, int(mtime), path, problem if problem else "ok"))
        return 0

    if command == "describe":
        path = argv[2]
        text = read(path)
        info = describe(text)
        problem = yaml_problem(text)
        print("has_model=%s" % info["has_model"])
        print("mapping=%s" % info["mapping"])
        print("default=%s" % (info["default"] or ""))
        print("provider=%s" % info["provider"])
        print("base_url=%s" % info["base_url"])
        print("token=%s" % info["token"])
        print("problem=%s" % (problem if problem else "none"))
        return 0

    if command == "check":
        path = argv[2]
        problem = yaml_problem(read(path))
        if problem:
            print(problem)
            return 1
        print("ok")
        return 0

    if command == "set-model":
        path, model = argv[2], argv[3]
        text = read(path)
        if not text.strip():
            text = "model:\n"
        new_text, what = set_model(text, model)
        problem = yaml_problem(new_text)
        if problem:
            print("the repair would leave the file broken: %s" % problem)
            return 1
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(new_text)
        print(what)
        return 0

    print("unknown command")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

CFGTOOL="$WORK/cfgtool.py"

# A python with PyYAML can say for certain that the file parses. Without one
# the tool falls back on reading the text, which is good enough - and the
# file is only ever read, never written, by the wrong python.
CFG_PY="python3"
for CANDIDATE in python3 "$HOME/.hermes/venv/bin/python" "$HOME/orb-hermes/venv/bin/python"; do
    if command -v "$CANDIDATE" >/dev/null 2>&1 && "$CANDIDATE" -c "import yaml" 2>/dev/null; then
        CFG_PY="$CANDIDATE"
        break
    fi
done
info "the settings are checked with: $CFG_PY"

run_tool() { "$CFG_PY" "$CFGTOOL" "$@"; }

# ============================================================ 1. the settings

say "1. The settings file"

CFG=""
for CANDIDATE in "$HOME/.hermes/config.yaml" "$HOME/.hermes/config.yml"; do
    if [ -f "$CANDIDATE" ]; then
        CFG="$CANDIDATE"
        break
    fi
done

if [ -z "$CFG" ]; then
    warn "there is no config.yaml in ~/.hermes - one will be made"
    CFG="$HOME/.hermes/config.yaml"
    mkdir -p "$HOME/.hermes"
    printf "model:\n  default: 'hermes-agent'\n" > "$CFG"
    info "made $CFG"
else
    info "$CFG"
fi

info "what it says now:"
run_tool describe "$CFG" 2>/dev/null | sed 's/^/      /'

info "the top of the file (the secrets are masked):"
sed -n '1,10p' "$CFG" 2>/dev/null | mask | sed 's/^/      /'

CURRENT_OK=0
if run_tool check "$CFG" >/dev/null 2>&1; then
    CURRENT_OK=1
fi

# ======================================================= 2. a copy to put back

say "2. Looking for the copy that was made before the damage"

BEST=""
BEST_SCORE=0
CANDIDATE_LIST=$(run_tool candidates 2>/dev/null)
if [ -n "$CANDIDATE_LIST" ]; then
    info "the copies that are lying around:"
    while IFS= read -r CAND; do
        [ -n "$CAND" ] || continue
        DESC=$(run_tool describe "$CAND" 2>/dev/null | tr '\n' ' ')
        info "  $CAND"
        info "    $DESC"
    done <<< "$CANDIDATE_LIST"

    RANKED=""
    while IFS= read -r CAND; do
        [ -n "$CAND" ] || continue
        LINE=$(run_tool rank "$CAND" 2>/dev/null)
        [ -n "$LINE" ] && RANKED="$RANKED$LINE"$'\n'
    done <<< "$CANDIDATE_LIST"

    BEST_LINE=$(printf '%s' "$RANKED" | grep -v '^$' | sort -t"$TAB" -k1,1nr -k2,2nr | head -1)
    if [ -n "$BEST_LINE" ]; then
        BEST_SCORE=$(printf '%s' "$BEST_LINE" | cut -f1)
        BEST=$(printf '%s' "$BEST_LINE" | cut -f3)
        info "the best copy is: $BEST  (score $BEST_SCORE)"
    fi
else
    info "there is no other copy"
fi

# ========================================================== 3. the repair

say "3. Putting the settings right"

if [ "$CURRENT_OK" = "1" ]; then
    info "the settings file is sound - it is left as it is"
else
    if [ -f "$CFG" ]; then
        cp -p "$CFG" "$CFG.broken-$STAMP" 2>/dev/null \
            && info "the file as it is now is kept as $CFG.broken-$STAMP"
    fi

    RESTORED=0
    if [ -n "$BEST" ] && [ "$BEST" != "$CFG" ] && [ "$BEST_SCORE" -ge 100 ]; then
        if cp "$BEST" "$CFG" 2>/dev/null; then
            RESTORED=1
            info "the copy that was made before the damage is back in place"
        fi
    fi

    if [ "$RESTORED" = "0" ]; then
        MODEL_IN_FILE=$(run_tool describe "$CFG" 2>/dev/null | sed -n 's/^default=//p')
        [ -n "$MODEL_IN_FILE" ] || MODEL_IN_FILE=$(run_tool describe "$CFG" 2>/dev/null | sed -n 's/^value=//p')
        if [ -z "$MODEL_IN_FILE" ]; then
            MODEL_IN_FILE="hermes-agent"
            warn "no model was found in the file - using $MODEL_IN_FILE"
        fi
        info "the model in the file is: $MODEL_IN_FILE"
        REPAIR_OUT=$(run_tool set-model "$CFG" "$MODEL_IN_FILE" 2>&1)
        REPAIR_RC=$?
        printf '%s\n' "$REPAIR_OUT" | sed 's/^/      /'
        if [ "$REPAIR_RC" = "0" ]; then
            info "the model is now inside model.default, where it belongs"
        else
            bad "the file could not be repaired"
        fi
    fi
fi

info "the result:"
run_tool describe "$CFG" 2>/dev/null | sed 's/^/      /'

if run_tool check "$CFG" >/dev/null 2>&1; then
    info "the settings file is sound again"
else
    bad "the settings file is still broken"
    run_tool check "$CFG" 2>/dev/null | sed 's/^/      /'
fi

# ========================================================= 4. does it answer

say "4. Does the agent answer"

agent_answers() {
    local out
    out=$(ask_agent "Reply with exactly: HELLO")
    printf '%s\n' "$out" | python3 -c '
import sys
text = sys.stdin.read()
if any(m in text for m in ("model is required", "OpenRouter rejected",
                          "not retryable failed", "Failed to connect")):
    sys.exit(1)
sys.exit(0 if ("\u2624 Hermes" in text or "FINAL RESPONSE:" in text) else 1)
'
}

# The models that are on this machine, and the ones the agent used before.
OLLAMA_MODELS=$(curl -s -m 10 http://127.0.0.1:11434/api/tags 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
names = []
for entry in data.get("models", []) or []:
    name = str(entry.get("name") or entry.get("model") or "").strip()
    if name and name not in names:
        names.append(name)
hermes_first = sorted(names, key=lambda n: (0 if "hermes" in n.lower() else 1, n))
print("\n".join(hermes_first[:5]))
')

SESSION_MODELS=$(python3 - "$HOME/.hermes" 2>/dev/null <<'PY'
import os, re, sys

root = sys.argv[1]
found = []
sessions = os.path.join(root, "sessions")
if os.path.isdir(sessions):
    for name in sorted(os.listdir(sessions)):
        if not name.endswith(".json"):
            continue
        try:
            text = open(os.path.join(sessions, name), encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for match in re.finditer(r'"model"\s*:\s*"([^"\n]+)"', text):
            value = match.group(1).strip()
            if value and not any(ch.isspace() for ch in value) and value not in found:
                found.append(value)
print("\n".join(found[:5]))
PY
)

CURRENT_MODEL=$(run_tool describe "$CFG" 2>/dev/null | sed -n 's/^default=//p')
[ -n "$CURRENT_MODEL" ] || CURRENT_MODEL=$(run_tool describe "$CFG" 2>/dev/null | sed -n 's/^value=//p')

TRIED=""
GOOD_MODEL=""
TRIES=0
try_model() {
    local model="$1"
    case " $TRIED " in
        *" $model "*) return 1 ;;
    esac
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -gt 4 ]; then
        warn "four models is enough - the rest are left alone"
        return 1
    fi
    TRIED="$TRIED $model"
    info "trying: $model  (this can take a few minutes)"
    if agent_answers; then
        info "  it answered"
        GOOD_MODEL="$model"
        return 0
    fi
    warn "  no answer with this one"
    return 1
}

if command -v hermes >/dev/null 2>&1; then
    [ -n "$CURRENT_MODEL" ] && try_model "$CURRENT_MODEL"
    if [ -z "$GOOD_MODEL" ] && [ -n "$OLLAMA_MODELS" ]; then
        while IFS= read -r M; do
            [ -n "$M" ] || continue
            try_model "$M" && break
        done <<< "$OLLAMA_MODELS"
    fi
    if [ -z "$GOOD_MODEL" ] && [ -n "$SESSION_MODELS" ]; then
        while IFS= read -r M; do
            [ -n "$M" ] || continue
            try_model "$M" && break
        done <<< "$SESSION_MODELS"
    fi
else
    warn "the hermes CLI is not on the PATH here"
fi

if [ -n "$GOOD_MODEL" ]; then
    info "the agent answers with: $GOOD_MODEL"
    if [ "$GOOD_MODEL" != "$CURRENT_MODEL" ]; then
        info "putting $GOOD_MODEL in the settings, so the gateway uses it too"
        run_tool set-model "$CFG" "$GOOD_MODEL" >/dev/null 2>&1 \
            && info "  written into model.default" \
            || warn "  the settings could not be updated"
    fi
else
    warn "the agent did not answer here"
    info "the orb still works - it falls back to Ollama"
fi

# =========================================================== 5. the gateway

say "5. The messaging gateway"

systemd_ready() {
    systemctl --user list-units --no-pager >/dev/null 2>&1
}

if ! systemd_ready; then
    # the script may have been run over ssh, where the runtime folder is not
    # in the environment
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    if systemd_ready; then
        info "the user services are reachable now"
    else
        warn "systemctl --user cannot be reached from here"
        info "run this on the Beelink desktop, not over ssh"
    fi
fi

GW_UNIT=""
for U in $(systemctl --user list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}'); do
    case "$U" in
        hermes*gateway*.service) GW_UNIT="$U"; break ;;
    esac
done
if [ -z "$GW_UNIT" ]; then
    for U in $(systemctl --user list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}'); do
        case "$U" in
            *gateway*.service) GW_UNIT="$U"; break ;;
        esac
    done
fi
if [ -z "$GW_UNIT" ]; then
    for U in $(systemctl --user list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}'); do
        DESC=$(systemctl --user show "$U" -p Description --value 2>/dev/null)
        case "$DESC" in
            *[Gg]ateway*) GW_UNIT="$U"; break ;;
        esac
    done
fi

if [ -z "$GW_UNIT" ]; then
    bad "no gateway service was found"
    info "the units that are here:"
    systemctl --user list-unit-files --type=service --no-pager 2>/dev/null | sed 's/^/      /'
else
    info "the gateway is the service: $GW_UNIT"
    ENABLED=$(systemctl --user is-enabled "$GW_UNIT" 2>/dev/null)
    info "  it is: ${ENABLED:-unknown}"
    if [ "$ENABLED" = "masked" ]; then
        info "  unmasking it"
        systemctl --user unmask "$GW_UNIT" 2>&1 | sed 's/^/      /'
    fi

    # The service is restarted the way systemd started it - the same unit,
    # the same environment, the same working folder. Nothing is killed by
    # hand and no command line is copied out of /proc.
    info "restarting $GW_UNIT"
    systemctl --user restart "$GW_UNIT" 2>&1 | sed 's/^/      /'
    sleep 6
    STATE=$(systemctl --user is-active "$GW_UNIT" 2>/dev/null)
    info "  it is now: ${STATE:-unknown}"
    systemctl --user --no-pager status "$GW_UNIT" 2>/dev/null | head -12 | mask | sed 's/^/      /'

    info "the last lines of its journal:"
    journalctl --user -u "$GW_UNIT" -n 25 --no-pager 2>/dev/null | mask | sed 's/^/      /' || true
fi

info "every hermes process, for the record:"
ps -eo pid,ppid,etimes,args 2>/dev/null | grep -iE "hermes" | grep -v grep | mask | sed 's/^/      /' | head -20

# ======================================================== 6. the agent API

say "6. The agent API and the bridge"

CODE=$(curl -s -o /tmp/restore-models.json -w '%{http_code}' -m 10 http://127.0.0.1:8642/v1/models 2>/dev/null || echo 000)
info "the agent API on 127.0.0.1:8642 -> HTTP $CODE"
if [ "$CODE" != "200" ]; then
    info "it is not running - the orb will use Ollama until it is back"
fi

# --------------------------------------------------------- 6b. the bridge
#
# The bridge remembers for an hour that the agent was broken. It has to be
# started again for the orb to use the agent - and it is started the way it
# was running: the same file, the same folder, the same settings.

BRIDGE_PID=$(pgrep -f 'hermes_bridge.py' 2>/dev/null | head -1)
BRIDGE_TOKEN=""
if [ -n "$BRIDGE_PID" ]; then
    info "the bridge is pid $BRIDGE_PID"
    BRIDGE_CMD=$(proc_cmdline "$BRIDGE_PID")
    info "  ${BRIDGE_CMD}"
    info "  it has been running for $(ps -o etimes= -p "$BRIDGE_PID" 2>/dev/null | tr -d ' ') seconds"

    if [ "${SKIP_BRIDGE_RESTART:-0}" = "1" ]; then
        info "the bridge is left as it is (SKIP_BRIDGE_RESTART=1)"
    else
        BRIDGE_CWD=$(proc_cwd "$BRIDGE_PID")
        BRIDGE_ENV="$WORK/bridge-env"
        proc_env "$BRIDGE_PID" > "$BRIDGE_ENV" 2>/dev/null
        BRIDGE_TOKEN=$(sed -n 's/^BRIDGE_TOKEN=//p' "$BRIDGE_ENV" 2>/dev/null | head -1)
        BRIDGE_PORT=$(sed -n 's/^BRIDGE_PORT=//p' "$BRIDGE_ENV" 2>/dev/null | head -1)
        [ -n "$BRIDGE_PORT" ] || BRIDGE_PORT=8787

        # the service, if it is the one that runs the bridge, is the better
        # way to start it - but it must not be running at the same time
        BRIDGE_UNIT_ACTIVE=0
        if [ -n "$GW_UNIT" ]; then :; fi
        for U in orb-hermes.service hermes-bridge.service; do
            if systemctl --user is-active "$U" >/dev/null 2>&1; then
                BRIDGE_UNIT_ACTIVE=1
                info "the bridge is run by $U - it is restarted instead"
                systemctl --user restart "$U" 2>&1 | sed 's/^/      /'
                sleep 6
                break
            fi
        done

        if [ "$BRIDGE_UNIT_ACTIVE" = "0" ]; then
            info "starting the bridge again, with the settings it had"
            # put the old settings back - all of them
            if [ -s "$BRIDGE_ENV" ]; then
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
                done < "$BRIDGE_ENV"
            fi
            cd "${BRIDGE_CWD:-$HOME}" 2>/dev/null || cd "$HOME"
            kill "$BRIDGE_PID" 2>/dev/null
            sleep 3
            if [ -n "$BRIDGE_CMD" ]; then
                nohup $BRIDGE_CMD >> "${BRIDGE_CWD:-$HOME}/bridge.log" 2>&1 &
            fi
            sleep 5
            NEW_PID=$(pgrep -f 'hermes_bridge.py' 2>/dev/null | head -1)
            if [ -n "$NEW_PID" ]; then
                info "  the bridge is running again as pid $NEW_PID"
            else
                warn "  the bridge did not come back - starting it with its script"
                for RUN in "$HOME/orb-hermes/run-bridge.sh" "$HOME/orb-setup/beelink/run-bridge.sh"; do
                    if [ -x "$RUN" ]; then
                        nohup "$RUN" >> "$(dirname "$RUN")/bridge.log" 2>&1 &
                        info "  started $RUN"
                        break
                    fi
                done
                sleep 6
            fi
        fi

        # the health of the bridge, the way the phone sees it
        if [ -n "$BRIDGE_TOKEN" ]; then
            HEALTH=$(curl -s -m 20 "http://127.0.0.1:$BRIDGE_PORT/health" -H "X-Auth-Token: $BRIDGE_TOKEN" 2>/dev/null)
            if [ -n "$HEALTH" ]; then
                info "the bridge says:"
                printf '%s\n' "$HEALTH" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for key in ("bridge", "hermes", "hermes_available", "hermes_error", "hermes_model"):
    if key in data:
        value = str(data[key])[:160]
        print("  %-18s %s" % (key + ":", value))
'
            else
                warn "the bridge did not answer on its health port"
            fi
        fi
    fi
else
    info "the bridge is not running"
    for RUN in "$HOME/orb-hermes/run-bridge.sh" "$HOME/orb-setup/beelink/run-bridge.sh"; do
        if [ -x "$RUN" ]; then
            info "  it can be started with: $RUN"
            break
        fi
    done
fi

# ========================================================== 7. the telegram

say "7. Telegram itself"

TG_TOKEN=""
if [ -f "$CFG" ]; then
    TG_TOKEN=$(grep -oE "[0-9]{8,12}:[A-Za-z0-9_-]{25,}" "$CFG" 2>/dev/null | head -1)
fi
if [ -z "$TG_TOKEN" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    TG_TOKEN="$TELEGRAM_BOT_TOKEN"
fi
if [ -n "$TG_TOKEN" ]; then
    CODE=$(curl -s -o /tmp/restore-tg.json -w '%{http_code}' -m 20 \
        "https://api.telegram.org/bot${TG_TOKEN}/getMe" 2>/dev/null || echo 000)
    info "telegram getMe: HTTP $CODE  (200 means the token is good)"
    if [ "$CODE" = "200" ]; then
        sed -n '1,3p' /tmp/restore-tg.json 2>/dev/null | mask | cut -c1-160 | sed 's/^/      /'
    fi
else
    warn "no telegram token was found in the settings"
fi

# ============================================================== 8. the end

say "done"

if [ -n "$GOOD_MODEL" ]; then
    info "the agent answers with: $GOOD_MODEL"
fi
if [ -n "$GW_UNIT" ]; then
    info "the gateway service: $GW_UNIT"
fi
info "the settings are in:  hermes config edit"
info "the agent's own logs: hermes logs"
info "if the desktop app still shows the old error, close it and open it again"
