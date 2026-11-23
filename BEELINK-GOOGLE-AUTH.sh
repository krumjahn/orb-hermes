#!/usr/bin/env bash
#
# BEELINK-GOOGLE-AUTH.sh - re-authorise Hermes against Google.
#
# Run this ON the Beelink (as the user that owns the Orb service):
#
#     curl -fsSL http://192.168.68.57:8899/BEELINK-GOOGLE-AUTH.sh | bash
#
# Why this is worth doing:
#
#   The google-workspace skill is installed and it was authorised once - the
#   OAuth client is from November, and the token that was written next to it
#   worked. The refresh token underneath that token has since been revoked by
#   Google, so the skill can no longer read the calendar or the mailbox:
#
#       TOKEN_REVOKED: invalid_grant: Token has been expired or revoked.
#
#   When that happens the agent does the wrong thing. It opens a browser,
#   hits the Google sign-in wall, and reports "the browser isn't logged in" -
#   which is not the fault. The token is. The skill says so itself:
#
#       Always check credential state before opening any browser.
#       Do NOT jump to the browser at the first sign of a missing credential.
#
#   This script re-runs the skill's own setup. It is interactive in exactly
#   one place - the Google consent screen - and everything else is checked
#   and reported.
#
# What it does, in order:
#
#   1. find the skill and the python that can run it
#   2. say what the credential state is right now
#   3. print the Google consent URL
#   4. read the auth code back and exchange it for a fresh token
#   5. prove it with a live API call
#   6. say what to do so the token does not die again
#
# The code can be given three ways, whichever is easiest:
#
#     curl -fsSL http://192.168.68.57:8899/BEELINK-GOOGLE-AUTH.sh | bash
#       -> the script asks for it on the terminal
#
#     GOOGLE_AUTH_CODE=... bash BEELINK-GOOGLE-AUTH.sh
#
#     bash BEELINK-GOOGLE-AUTH.sh <code>
#
set -uo pipefail

HERMES_DIR="${HERMES_HOME:-$HOME/.hermes}"
SKILL_DIR="$HERMES_DIR/skills/productivity/google-workspace"
SETUP="$SKILL_DIR/scripts/setup.py"
TOKEN_FILE="$HERMES_DIR/google_token.json"
CLIENT_FILE="$HERMES_DIR/google_client_secret.json"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m    %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------- 1. the skill and python

say "1. The skill"

if [ ! -f "$SETUP" ]; then
    warn "the google-workspace skill is not where it should be"
    info "looked for: $SETUP"
    die "nothing was changed"
fi
info "the skill: $SKILL_DIR"

# The setup script has to run under the python that belongs to Hermes, not an
# unrelated system python - the Google extra may only be installed there.
PY=""
for CANDIDATE in \
    "${HERMES_PYTHON:-}" \
    "$HERMES_DIR/hermes-agent/.venv/bin/python" \
    "$HERMES_DIR/venv/bin/python" \
    "$(command -v python3 2>/dev/null)" \
    "$(command -v python 2>/dev/null)"
do
    [ -n "$CANDIDATE" ] || continue
    [ -x "$CANDIDATE" ] || continue
    if "$CANDIDATE" "$SETUP" --check >/dev/null 2>&1; then
        PY="$CANDIDATE"
        break
    fi
    # a python that cannot even run the script is not the right one, but one
    # that can run it and reports "not authenticated" is fine
    if "$CANDIDATE" "$SETUP" --help >/dev/null 2>&1; then
        PY="$CANDIDATE"
        break
    fi
done

if [ -z "$PY" ]; then
    warn "no python could run $SETUP"
    info "try it by hand:"
    info "  python3 $SETUP --check"
    die "nothing was changed"
fi
info "python: $PY"

# ---------------------------------------------------- 2. what the state is now

say "2. The credential state"

if [ -f "$CLIENT_FILE" ]; then
    info "the OAuth client is there: $CLIENT_FILE"
    info "  written: $(date -r "$CLIENT_FILE" '+%Y-%m-%d %H:%M' 2>/dev/null)"
else
    warn "there is no OAuth client: $CLIENT_FILE"
    info "the skill needs one, and it is a one-time job in the Google Cloud Console:"
    info "  https://console.cloud.google.com/apis/credentials"
    info "  Credentials -> Create Credentials -> OAuth 2.0 Client ID -> Desktop app"
    info "then run this again with the file:"
    info "  $PY $SETUP --client-secret /path/to/client_secret.json"
    die "nothing was changed"
fi

if [ -f "$TOKEN_FILE" ]; then
    info "the token is there: $TOKEN_FILE"
    info "  written: $(date -r "$TOKEN_FILE" '+%Y-%m-%d %H:%M' 2>/dev/null)"
else
    info "there is no token yet - this has never been authorised"
fi

CHECK_OUT=$("$PY" "$SETUP" --check 2>&1)
CHECK_RC=$?
info "$CHECK_OUT"
if [ "$CHECK_RC" -eq 0 ]; then
    say "The credential is already good - nothing to do."
    info "The orb can read the calendar and the mailbox."
    exit 0
fi

# --------------------------------------------------------- 3. the consent URL

say "3. Authorise with Google"

AUTH_OUT=$("$PY" "$SETUP" --auth-url 2>&1)
AUTH_RC=$?
if [ "$AUTH_RC" -ne 0 ]; then
    warn "the skill would not print an authorisation URL:"
    printf '%s\n' "$AUTH_OUT" | sed 's/^/    /'
    die "nothing was changed"
fi
printf '%s\n' "$AUTH_OUT" | sed 's/^/    /'

printf '\n'
info "Open that URL on your phone, sign in as yourself, and agree to the request."
info "Google then tries to send the browser to a local address, and the page"
info "will not load - that is expected. The code is in the address bar:"
info "    http://localhost:PORT/?code=PASTE_HERE&scope=..."
info "Copy the code (or the whole URL) and paste it below."
printf '\n'

# ------------------------------------------------------------- 4. the code in

CODE="${1:-${GOOGLE_AUTH_CODE:-}}"
if [ -z "$CODE" ]; then
    if [ -r /dev/tty ]; then
        printf '    the code (or the whole URL): '
        read -r CODE < /dev/tty || CODE=""
        printf '\n'
    else
        warn "no terminal to read the code from"
        info "give it as an argument instead:"
        info "  bash BEELINK-GOOGLE-AUTH.sh <code>"
        die "nothing was changed"
    fi
fi

# a whole URL was pasted - take the code out of it
case "$CODE" in
    *code=*) CODE="${CODE#*code=}"; CODE="${CODE%%&*}" ;;
esac
CODE="$(printf '%s' "$CODE" | tr -d '[:space:]')"

if [ -z "$CODE" ]; then
    die "no code was given"
fi

# the old token is kept as a backup, so a mistake here can be undone
if [ -f "$TOKEN_FILE" ]; then
    cp "$TOKEN_FILE" "$TOKEN_FILE.bak-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    info "the old token was kept as a backup"
fi

say "4. Exchanging the code for a token"
EXCHANGE_OUT=$("$PY" "$SETUP" --auth-code "$CODE" 2>&1)
EXCHANGE_RC=$?
printf '%s\n' "$EXCHANGE_OUT" | sed 's/^/    /'
if [ "$EXCHANGE_RC" -ne 0 ]; then
    warn "the code was not accepted"
    warn "a code can only be used once, and only for a few minutes - run this"
    warn "again and use a fresh code."
    die "the credential was not changed"
fi

# ------------------------------------------------------------- 5. the proof

say "5. Proving it"

AGAIN=$("$PY" "$SETUP" --check 2>&1)
AGAIN_RC=$?
if [ "$AGAIN_RC" -ne 0 ]; then
    warn "$AGAIN"
    die "the token was not accepted"
fi
info "$AGAIN"

LIVE_OUT=$("$PY" "$SETUP" --check-live 2>&1)
LIVE_RC=$?
printf '%s\n' "$LIVE_OUT" | sed 's/^/    /'
if [ "$LIVE_RC" -ne 0 ]; then
    warn "the token is stored but a live Google call did not work"
    warn "the grant may be missing the calendar scope - re-authorise and"
    warn "ask for calendar when Google shows the consent screen."
    exit 1
fi
info "a live Google call worked"

if [ -f "$TOKEN_FILE" ]; then
    info "the token was written: $(date -r "$TOKEN_FILE" '+%Y-%m-%d %H:%M' 2>/dev/null)"
fi

# --------------------------------------------------------------- 6. the rest

say "6. So that it does not die again"

cat <<'EOF'
    A Google OAuth token lasts as long as the grant behind it does.

    If the OAuth app is still in TESTING in the Google Cloud Console, Google
    only keeps the refresh token for seven days, and it then expires on its
    own - which is the usual reason a working token suddenly stops working.

    To make it last:

      https://console.cloud.google.com/auth/audience
        -> the consent screen -> publish it (Production), and add your own
           Google account as a test user while it is still in Testing.

      https://console.cloud.google.com/apis/credentials
        -> the OAuth client -> make sure the Calendar API is enabled in the
           project's API library.

    And if Google says the grant was revoked, look here:

      your Google account -> Security -> third-party connections
        -> "Hermes" (or whatever the app is called) -> remove it, and
           re-authorise with this script.

    Check the state at any time with:

      python3 ~/.hermes/skills/productivity/google-workspace/scripts/setup.py --check
EOF

say "Done"
info "ask the orb what is on your calendar - it should answer from Google now."
info "if it still answers from your notes, the notes are what it read:"
info "  ~/.hermes/profiles/memory/HKIS_CALENDAR.md"
