#!/usr/bin/env bash
#
# BEELINK-FINAL.sh - the last two changes in one go.
#
#   1. point the orb at the Hermes agent, so it has the memory and the tools
#   2. give it a female voice
#
# Run this ON the Beelink:
#
#     curl -fsSL http://192.168.1.10:8899/BEELINK-FINAL.sh | bash -s -- English_SereneWoman
#
# The argument is the voice id. Leave it out for English_SereneWoman.
# Run BEELINK-VOICE.sh on its own to change the voice later.
#
set -uo pipefail

MAC="http://192.168.1.10:8899"
VOICE="${1:-English_SereneWoman}"

printf '\n\033[1;36m==> step 1 of 2: the Hermes agent (the brain with the memory)\033[0m\n'
if curl -fsSL --max-time 120 "$MAC/BEELINK-HERMES-BACKEND.sh" | bash; then
    printf '\n\033[1;32m    step 1 finished\033[0m\n'
else
    printf '\n\033[1;31m    step 1 did not finish - read its output above.\033[0m\n'
    printf '    The voice can still be set with:\n'
    printf '        curl -fsSL %s/BEELINK-VOICE.sh | bash -s -- %s\n' "$MAC" "$VOICE"
    exit 1
fi

printf '\n\033[1;36m==> step 2 of 2: the voice (%s)\033[0m\n' "$VOICE"
if curl -fsSL --max-time 120 "$MAC/BEELINK-VOICE.sh" | bash -s -- "$VOICE"; then
    printf '\n\033[1;32m    step 2 finished\033[0m\n'
else
    printf '\n\033[1;31m    step 2 did not finish - read its output above.\033[0m\n'
    exit 1
fi

printf '\n\033[1;32m==> both done - say "Orbit, what time is it?" to the phone\033[0m\n'
