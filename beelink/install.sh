#!/usr/bin/env bash
#
# install.sh - one-command installer for the Orb Hermes bridge.
#
# Use this on the Beelink when SSH is awkward, e.g. from the Synology DSM
# Task Scheduler (Control Panel -> Task Scheduler -> Create -> User-defined
# script -> run as your own user):
#
#     bash ~/orb-setup/install.sh
#
# It generates the shared token itself, runs the real installer, and prints the
# token so you can paste it into the phone.
#
# Options (all optional):
#   --token SECRET   use this token instead of generating one
#   --transport MODE tailscale | cloudflare | none   (default: none, home LAN)
#   --wake WORD      wake phrase (default: orbit)
#   --port PORT      bridge port (default: 8787)
#   --ollama-model NAME  talk to this Ollama model (default: newest *-hermes*)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# this script ships inside the 'beelink' folder, but also has to work when it
# is run from the folder that contains it
if [[ -f "$HERE/setup-beelink.sh" ]]; then
  BRIDGE_DIR="$HERE"
elif [[ -f "$HERE/beelink/setup-beelink.sh" ]]; then
  BRIDGE_DIR="$HERE/beelink"
else
  echo "Cannot find setup-beelink.sh next to this script or in ./beelink" >&2
  echo "Unzip orb-hermes-beelink-setup.zip so that the 'beelink' folder is intact." >&2
  exit 1
fi

TOKEN=""
TRANSPORT="none"
WAKE="orbit"
PORT="8787"
OLLAMA_MODEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --transport) TRANSPORT="$2"; shift 2 ;;
    --wake) WAKE="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --ollama-model) OLLAMA_MODEL="$2"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "$BRIDGE_DIR/setup-beelink.sh" ]]; then
  echo "Cannot find $BRIDGE_DIR/setup-beelink.sh" >&2
  exit 1
fi

if [[ -z "$TOKEN" ]]; then
  TOKEN="$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  echo "Generated a shared token: $TOKEN"
fi

mkdir -p "$HOME/orb-hermes"
printf '%s' "$TOKEN" > "$HOME/orb-hermes/TOKEN"
chmod 600 "$HOME/orb-hermes/TOKEN"

bash "$BRIDGE_DIR/setup-beelink.sh" \
  --token "$TOKEN" --transport "$TRANSPORT" --wake "$WAKE" --port "$PORT" \
  --ollama-model "$OLLAMA_MODEL"

echo
echo "================================================================"
echo " Orb Hermes bridge installed."
echo
echo "   Hermes server : http://<beelink-address>:$PORT"
echo "   Access token  : $TOKEN"
echo
echo " The token is also saved at $HOME/orb-hermes/TOKEN"
echo "================================================================"
