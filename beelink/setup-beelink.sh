#!/usr/bin/env bash
#
# setup-beelink.sh - one-shot installer for the Orb Hermes bridge.
#
# Run this on the Beelink (the machine that runs Hermes):
#
#     scp -r beelink/ keith@192.168.1.50:~/orb-hermes-setup
#     ssh keith@192.168.1.50 'cd ~/orb-hermes-setup && ./setup-beelink.sh --token YOUR_SECRET'
#
# Options:
#   --token SECRET      shared secret the phone must present (X-Auth-Token)
#   --transport MODE    tailscale | cloudflare | none   (default: none, home LAN)
#   --port PORT         bridge port (default 8787)
#   --wake WORD         wake phrase the bridge listens for (default: orbit)
#   --ollama-model NAME Ollama model to talk to (default: newest *-hermes* model)
#   --no-voice          skip installing speech dependencies
#   --skip-tailscale    do not install Tailscale
#
# The installer works on a normal Linux box and on Synology DSM / Xpenology:
# it detects whether Hermes runs natively or inside Docker, it finds the
# Ollama model to talk to, and it falls back from a systemd user service to a
# boot script to a cron job.
#
set -euo pipefail

TOKEN=""
# plain home LAN by default - the transport that was chosen for this setup.
# 'tailscale' is still available with --transport tailscale.
TRANSPORT="none"
PORT="8787"
WAKE="orbit"
OLLAMA_MODEL=""
INSTALL_VOICE=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --transport) TRANSPORT="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --wake) WAKE="$2"; shift 2 ;;
    --ollama-model) OLLAMA_MODEL="$2"; shift 2 ;;
    --no-voice) INSTALL_VOICE=0; shift ;;
    --skip-tailscale) TRANSPORT="none"; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

INSTALL_DIR="$HOME/orb-hermes"
SERVICE_USER="$(id -un)"
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }

say "Installing the Orb Hermes bridge into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cp "$(dirname "$0")/hermes_bridge.py" "$INSTALL_DIR/hermes_bridge.py"
chmod +x "$INSTALL_DIR/hermes_bridge.py"
cp "$(dirname "$0")/selftest-stt.py" "$INSTALL_DIR/selftest-stt.py"
chmod +x "$INSTALL_DIR/selftest-stt.py"

# ---------------------------------------------------------------- hermes api
say "Checking the Hermes API server"

HERMES_CONTAINER=""
if command -v docker >/dev/null 2>&1; then
  HERMES_CONTAINER="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i hermes | head -1 || true)"
fi

if [[ -n "$HERMES_CONTAINER" ]]; then
  # Hermes runs in Docker: add the settings through a compose override so the
  # original compose file is never touched.
  SERVICE="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$HERMES_CONTAINER" 2>/dev/null || true)"
  PROJECT_DIR="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$HERMES_CONTAINER" 2>/dev/null || true)"

  if [[ -n "$SERVICE" && -n "$PROJECT_DIR" && -d "$PROJECT_DIR" ]]; then
    OVERRIDE="$PROJECT_DIR/docker-compose.override.yml"
    info "Hermes container: $HERMES_CONTAINER (service '$SERVICE')"
    cat > "$OVERRIDE" <<EOF
# Added by Orb Hermes setup
services:
  $SERVICE:
    environment:
      - API_SERVER_ENABLED=true
      - API_SERVER_KEY=${TOKEN:-change-me-local-dev}
EOF
    info "wrote $OVERRIDE"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      (cd "$PROJECT_DIR" && docker compose up -d) && info "restarted the Hermes container"
    else
      warn "docker compose is unavailable - restart the container from Container Manager by hand"
    fi
  else
    warn "Hermes container '$HERMES_CONTAINER' was not started by compose."
    warn "Recreate it with these two variables added to the environment:"
    warn "    API_SERVER_ENABLED=true"
    warn "    API_SERVER_KEY=${TOKEN:-change-me-local-dev}"
  fi
else
  HERMES_ENV="$HOME/.hermes/.env"
  mkdir -p "$HOME/.hermes"
  touch "$HERMES_ENV"
  if grep -q "^API_SERVER_ENABLED=true" "$HERMES_ENV"; then
    info "API server already enabled in $HERMES_ENV"
  else
    cp "$HERMES_ENV" "$HERMES_ENV.bak"
    cat >> "$HERMES_ENV" <<EOF

# Added by Orb Hermes setup
API_SERVER_ENABLED=true
API_SERVER_KEY=${TOKEN:-change-me-local-dev}
EOF
    info "Enabled API_SERVER in $HERMES_ENV (previous contents backed up to .env.bak)"
  fi
  info "restarting Hermes so it picks up the change"
fi

# ------------------------------------------------------------ restart hermes
say "Restarting Hermes"
hermes_restarted=0

if command -v docker >/dev/null 2>&1 && [[ -n "$HERMES_CONTAINER" ]]; then
  if docker restart "$HERMES_CONTAINER" >/dev/null 2>&1; then
    info "restarted container $HERMES_CONTAINER"
    hermes_restarted=1
  fi
fi

if [[ "$hermes_restarted" == "0" ]]; then
  for unit in hermes hermes-agent hermes-agent.service hermes.service; do
    if command -v systemctl >/dev/null 2>&1 && run_quiet systemctl --user list-unit-files && systemctl --user list-unit-files 2>/dev/null | grep -q "^$unit"; then
      systemctl --user restart "$unit" && info "restarted systemd unit $unit" && hermes_restarted=1 && break
    fi
    if command -v systemctl >/dev/null 2>&1 && run_quiet systemctl list-unit-files && systemctl list-unit-files 2>/dev/null | grep -q "^$unit"; then
      # -n so we never block waiting for a password prompt
      sudo -n systemctl restart "$unit" && info "restarted systemd unit $unit" && hermes_restarted=1 && break
    fi
    if command -v synosystemctl >/dev/null 2>&1 && run_quiet synosystemctl list && synosystemctl list 2>/dev/null | grep -qi hermes; then
      synosystemctl restart hermes-agent 2>/dev/null && info "restarted the hermes-agent package" && hermes_restarted=1 && break
    fi
  done
fi

if [[ "$hermes_restarted" == "0" ]]; then
  warn "could not restart Hermes automatically - restart it yourself, then check:"
  warn "    curl -s http://127.0.0.1:8642/v1/models -H 'Authorization: Bearer $TOKEN'"
fi

if ! command -v hermes >/dev/null 2>&1 && ! command -v hermes-agent >/dev/null 2>&1; then
  warn "the 'hermes' CLI is not on PATH - the bridge will need the API server on :8642"
fi

# ------------------------------------------------------------------- voice
VENV="$INSTALL_DIR/venv"
if [[ "$INSTALL_VOICE" == "1" ]]; then
  say "Installing speech dependencies"
  PY="$(command -v python3 || true)"
  if [[ -z "$PY" ]]; then
    for candidate in /usr/local/bin/python3 /usr/bin/python3 /opt/homebrew/bin/python3; do
      if [[ -x "$candidate" ]]; then PY="$candidate"; break; fi
    done
  fi
  if [[ -n "$PY" ]]; then
    info "python3: $PY"
    # a venv keeps us clear of externally-managed python installs (Arch) and
    # of the system python on other distros
    if "$PY" -m venv "$VENV" 2>/dev/null; then
      VENV_PY="$VENV/bin/python"
      info "created $VENV"
      "$VENV_PY" -m pip install --quiet --upgrade pip 2>&1 | tail -1 || true
      echo "-> edge-tts (free neural TTS, no API key)"
      "$VENV_PY" -m pip install --quiet edge-tts 2>&1 | tail -1 || warn "edge-tts install failed"
      echo "-> faster-whisper (local speech-to-text)"
      # No PyAV pin here on purpose. faster-whisper hands a file path to PyAV,
      # and PyAV 15+ dropped the 'metadata_errors' argument it still passes,
      # so a pinned-old PyAV has no wheel for python 3.14 and the install
      # fails outright. The bridge now reads the wav itself (load_audio) and
      # never calls PyAV, so any PyAV version works.
      "$VENV_PY" -m pip install --quiet faster-whisper 2>&1 | tail -1 || warn "faster-whisper install failed"
      echo "-> downloading the whisper model now (so the first wake word is not slow)"
      "$VENV_PY" -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8'); print('model ready')" \
        2>&1 | tail -2 || warn "model download failed - it will retry on first use"
      echo "-> checking that speech-to-text actually works"
      ORB_BRIDGE="$INSTALL_DIR/hermes_bridge.py" "$VENV_PY" "$INSTALL_DIR/selftest-stt.py" 2>&1 | tail -3 \
        || warn "speech-to-text self-test failed - the wake word will not work"
    else
      warn "could not create a venv - falling back to a --user install"
      "$PY" -m pip install --user --quiet edge-tts 2>&1 | tail -1 || warn "edge-tts install failed"
      "$PY" -m pip install --user --quiet faster-whisper 2>&1 | tail -1 || warn "faster-whisper install failed"
      "$PY" -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8'); print('model ready')" \
        2>&1 | tail -2 || warn "model download failed - it will retry on first use"
      echo "-> checking that speech-to-text actually works"
      ORB_BRIDGE="$INSTALL_DIR/hermes_bridge.py" "$PY" "$INSTALL_DIR/selftest-stt.py" 2>&1 | tail -3 \
        || warn "speech-to-text self-test failed - the wake word will not work"
    fi
    echo "-> adding ~/.local/bin to PATH in ~/.profile"
    grep -q 'HOME/.local/bin' "$HOME/.profile" 2>/dev/null || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.profile"
  else
    warn "python3 not found - skipping speech dependencies"
  fi
  if command -v npm >/dev/null 2>&1; then
    echo "-> mmx-cli (MiniMax TTS, optional - needs an API key)"
    npm install -g mmx-cli >/dev/null 2>&1 || warn "mmx-cli install failed"
    command -v mmx >/dev/null 2>&1 && echo "   run: mmx auth login --api-key sk-xxxxx"
  else
    warn "npm not found - skipping mmx-cli (optional)"
  fi
fi

# ------------------------------------------------------------------- ollama
say "Looking for the Ollama model to talk to"
OLLAMA_URL_VALUE="http://127.0.0.1:11434"
if [[ -z "$OLLAMA_MODEL" ]]; then
  OLLAMA_MODEL="$(curl -s --max-time 5 "$OLLAMA_URL_VALUE/api/tags" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
models = data.get("models") or []
models.sort(key=lambda m: m.get("modified") or "", reverse=True)
names = [m.get("name", "") for m in models]
hermes = [n for n in names if "hermes" in n.lower()]
print((hermes or names or [""])[0])
' 2>/dev/null || true)"
fi
if [[ -n "$OLLAMA_MODEL" ]]; then
  info "ollama model: $OLLAMA_MODEL"
else
  warn "no Ollama model found - the bridge will rely on the Hermes API server"
fi

# ----------------------------------------------------------------- service
say "Writing the service"

cat > "$INSTALL_DIR/run-bridge.sh" <<EOF
#!/usr/bin/env bash
# Started by the Orb Hermes bridge service.
export BRIDGE_HOST=0.0.0.0
export BRIDGE_PORT=${PORT}
export BRIDGE_TOKEN=${TOKEN}
export HERMES_BASE_URL=http://127.0.0.1:8642/v1
export HERMES_API_KEY=${TOKEN}
export HERMES_MODEL=hermes-agent
export OLLAMA_URL=${OLLAMA_URL_VALUE}
export OLLAMA_MODEL=${OLLAMA_MODEL}
export WAKE_PHRASE=${WAKE}
export PATH="${INSTALL_DIR}/venv/bin:\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:\$PATH"
BRIDGE_PY="${INSTALL_DIR}/venv/bin/python"
if [ ! -x "\$BRIDGE_PY" ]; then BRIDGE_PY=python3; fi
exec "\$BRIDGE_PY" ${INSTALL_DIR}/hermes_bridge.py
EOF
chmod +x "$INSTALL_DIR/run-bridge.sh"

service_started=0

# systemctl --user can hang on Synology, so never wait on it indefinitely
run_quiet() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 8 "$@" >/dev/null 2>&1
  else
    "$@" >/dev/null 2>&1
  fi
}

if command -v systemctl >/dev/null 2>&1 && run_quiet systemctl --user show-environment; then
  say "Installing a systemd user service"
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/orb-hermes.service" <<EOF
[Unit]
Description=Orb Hermes bridge (phone -> Hermes agent)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/run-bridge.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now orb-hermes.service && service_started=1
  systemctl --user --no-pager status orb-hermes.service | head -8 || true
  sudo -n loginctl enable-linger "$SERVICE_USER" 2>/dev/null || true
  info "logs: journalctl --user -u orb-hermes -f"
elif command -v synosystemctl >/dev/null 2>&1 && [[ -w /usr/local/etc/rc.d ]]; then
  say "Installing a DSM boot script (needs root)"
  cat > /usr/local/etc/rc.d/S99orb-hermes.sh <<EOF
#!/bin/sh
# Added by Orb Hermes setup
su - "$SERVICE_USER" -c "${INSTALL_DIR}/run-bridge.sh" >> /tmp/orb-hermes.log 2>&1 &
EOF
  chmod +x /usr/local/etc/rc.d/S99orb-hermes.sh
  su - "$SERVICE_USER" -c "nohup ${INSTALL_DIR}/run-bridge.sh >> /tmp/orb-hermes.log 2>&1 &"
  service_started=1
  info "logs: tail -f /tmp/orb-hermes.log"
else
  say "Installing a cron job (no systemd, no root)"
  ( crontab -l 2>/dev/null | grep -v 'orb-hermes/run-bridge.sh' || true; \
    echo "@reboot ${INSTALL_DIR}/run-bridge.sh >> /tmp/orb-hermes.log 2>&1" ) | crontab -
  nohup "$INSTALL_DIR/run-bridge.sh" >> /tmp/orb-hermes.log 2>&1 &
  service_started=1
  info "logs: tail -f /tmp/orb-hermes.log"
fi

if [[ "$service_started" == "1" ]]; then
  sleep 2
  info "bridge health: $(curl -s --max-time 5 "http://127.0.0.1:${PORT}/health" || echo 'not answering yet')"
fi

# ------------------------------------------------------------------ network
say "Working out the LAN address"
# the '|| true' inside the braces keeps a missing tool from killing the
# installer - 'set -o pipefail' would otherwise abort on the failed command
LAN_IP="$( { hostname -I 2>/dev/null || true; } | awk '{print $1}')"
if [[ -z "$LAN_IP" ]]; then
  LAN_IP="$( { ip -4 addr show scope global 2>/dev/null || true; } | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
fi
if [[ -z "$LAN_IP" ]]; then
  LAN_IP="$( { hostname -i 2>/dev/null || true; } | awk '{print $1}')"
fi
LAN_CIDR=""
if [[ -n "$LAN_IP" ]]; then
  LAN_CIDR="$(python3 - "$LAN_IP" <<'PY' 2>/dev/null || true
import ipaddress, sys
try:
    print(ipaddress.ip_network(sys.argv[1] + "/24", strict=False))
except Exception:
    pass
PY
)"
fi
if [[ -n "$LAN_IP" ]]; then
  info "LAN address: $LAN_IP${LAN_CIDR:+ (network $LAN_CIDR)}"
else
  warn "could not detect this machine's LAN address"
fi

# ----------------------------------------------------------------- firewall
say "Opening the firewall for TCP $PORT"
firewall_opened=0
if command -v ufw >/dev/null 2>&1; then
  if [[ -n "$LAN_CIDR" ]] && sudo -n ufw allow from "$LAN_CIDR" to any port "$PORT" proto tcp >/dev/null 2>&1; then
    info "ufw: allowed $PORT from $LAN_CIDR"
    firewall_opened=1
  fi
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  if sudo -n firewall-cmd --permanent --add-port="$PORT/tcp" >/dev/null 2>&1 \
     && sudo -n firewall-cmd --reload >/dev/null 2>&1; then
    info "firewalld: opened $PORT/tcp"
    firewall_opened=1
  fi
fi
if [[ "$firewall_opened" == "0" ]]; then
  if sudo -n nft add rule inet filter input tcp dport "$PORT" accept >/dev/null 2>&1; then
    info "nftables: accepted tcp dport $PORT"
    firewall_opened=1
  elif sudo -n iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT >/dev/null 2>&1; then
    info "iptables: accepted tcp dport $PORT"
    firewall_opened=1
  fi
fi
if [[ "$firewall_opened" == "0" ]]; then
  warn "could not open the firewall automatically (sudo wants a password)."
  warn "Run one of these on the Beelink so the phone can reach the bridge:"
  warn "    sudo ufw allow from ${LAN_CIDR:-192.168.0.0/16} to any port $PORT proto tcp"
  warn "    sudo firewall-cmd --permanent --add-port=$PORT/tcp && sudo firewall-cmd --reload"
  warn "    sudo nft add rule inet filter input tcp dport $PORT accept"
fi

# --------------------------------------------------------------- transport
case "$TRANSPORT" in
  tailscale)
    say "Installing Tailscale on the Beelink"
    if ! command -v tailscale >/dev/null 2>&1; then
      curl -fsSL https://tailscale.com/install.sh | sh || warn "tailscale install failed"
    else
      info "tailscale already installed"
    fi
    echo
    echo "Now log in and approve the Beelink on your tailnet:"
    echo "    sudo tailscale up"
    echo "It prints a login URL - open it on any device and sign in."
    echo "Then install the Tailscale app on the Samsung (Play Store) and sign in"
    echo "with the same account. The phone reaches Hermes at http://<tailscale-ip>:${PORT}"
    echo "Do NOT install Tailscale on the Mac - it is what breaks your Mac's connection."
    ;;
  cloudflare)
    say "Setting up a Cloudflare quick tunnel"
    if ! command -v cloudflared >/dev/null 2>&1; then
      warn "install cloudflared first: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    fi
    echo "Run: cloudflared tunnel --url http://127.0.0.1:${PORT}"
    echo "It prints a https://<random>.trycloudflare.com URL - put that in the"
    echo "phone's Settings, with the token in the Access token field."
    ;;
  *)
    echo "No transport installed. The phone can reach the bridge on this LAN:"
    if [[ -n "$LAN_IP" ]]; then
      echo "    http://${LAN_IP}:${PORT}"
    else
      echo "    http://<this-machine's-ip>:${PORT}"
    fi
    ;;
esac

say "Done"
cat <<EOF

Local check:
    curl -s http://127.0.0.1:${PORT}/health

In the phone app (tap the orb, then the gear), set:
    Hermes server : http://<beelink-address>:${PORT}
    Access token  : ${TOKEN}
    Wake word     : ${WAKE}

EOF
