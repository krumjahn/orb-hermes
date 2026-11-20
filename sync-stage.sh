#!/usr/bin/env bash
#
# sync-stage.sh - refresh the folder that the Beelink downloads from.
#
# The Beelink fetches its files over plain HTTP from the Mac, so the staged
# copies have to be byte-identical to the ones in the project. This script
# copies them and checks that they are actually being served.
#
#   bash sync-stage.sh
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORB_SRC="${ORB_SRC:-$PROJECT_DIR/beelink}"
NOTES_SRC="${NOTES_SRC:-}"
RUNTIME="${ORB_RUNTIME:-$HOME/.orb-hermes}"
STAGE="$RUNTIME/stage"
PUBLIC_URL="${ORB_PUBLIC_URL:-http://192.168.1.10:8899}"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }

mkdir -p "$STAGE" "$RUNTIME/logs"

# The relay itself runs from the runtime directory, so a reboot cannot lose it.
if [ -f "$ORB_SRC/relay_mac.py" ]; then
    install -m 0644 "$ORB_SRC/relay_mac.py" "$RUNTIME/relay_mac.py"
fi

missing=0
for f in hermes_bridge.py selftest-stt.py setup-beelink.sh install.sh relay_dialer.py relay_mac.py; do
    if [ -f "$ORB_SRC/$f" ]; then
        install -m 0644 "$ORB_SRC/$f" "$STAGE/$f"
    else
        say "missing source file: $ORB_SRC/$f"
        missing=1
    fi
done

# the notes daemon lives in its own repository, so it is only staged when
# that repository is present and pointed at
if [ -n "$NOTES_SRC" ]; then
    for f in hermes_notes.py nas_client.py install-user.sh; do
        if [ -f "$NOTES_SRC/$f" ]; then
            install -m 0644 "$NOTES_SRC/$f" "$STAGE/$f"
        else
            say "missing source file: $NOTES_SRC/$f"
            missing=1
        fi
    done
fi

# the one-shot fix for the Beelink lives at the top of this project
for f in BEELINK-QUICKFIX.sh BEELINK-HERMES-BACKEND.sh BEELINK-VOICE.sh BEELINK-FINAL.sh BEELINK-BRIDGE-UPDATE.sh BEELINK-HERMES-DIAG.sh BEELINK-HERMES-RESTORE.sh BEELINK-BRIDGE-CLEAN.sh BEELINK-AGENT-VERIFY.sh; do
    if [ -f "$PROJECT_DIR/$f" ]; then
        install -m 0755 "$PROJECT_DIR/$f" "$STAGE/$f"
    else
        say "missing source file: $PROJECT_DIR/$f"
        missing=1
    fi
done

[ "$missing" -eq 0 ] || exit 1

chmod +x "$STAGE"/*.sh "$STAGE/selftest-stt.py" 2>/dev/null || true

say "staged files"
ls -1 "$STAGE" | sed 's/^/    /'

say "checking the download link"
fail=0
for f in $(ls "$STAGE"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$PUBLIC_URL/$f" || echo 000)
    [ "$code" = "200" ] || fail=1
    printf '    %-24s %s\n' "$f" "$code"
done

if [ "$fail" -ne 0 ]; then
    say "the staging server is not serving everything - check the job that serves $STAGE"
    exit 1
fi

# The dialer is the one file whose whole job is the timeout, so check it here.
if grep -q "bridge.settimeout(BRIDGE_TIMEOUT)" "$STAGE/relay_dialer.py"; then
    info "relay_dialer.py carries the long timeout fix"
else
    say "relay_dialer.py is missing the timeout fix - do not let anyone install it"
    exit 1
fi

say "ready for the Beelink at $PUBLIC_URL"
