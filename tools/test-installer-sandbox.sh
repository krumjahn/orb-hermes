#!/usr/bin/env bash
#
# test-installer-sandbox.sh - run install.sh in a throwaway sandbox and prove
# it produces a correct run-bridge.sh, without touching the real machine.
#
# Everything the installer touches (HOME, crontab, systemctl, docker, sudo,
# npm, curl, python3) is redirected to stubs inside a temp directory.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BEELINK_DIR="$HERE/beelink"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

FAILS=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

echo "Sandbox: $SANDBOX"

# ---------------------------------------------------------------- stubs
mkdir -p "$SANDBOX/bin" "$SANDBOX/home"

cat > "$SANDBOX/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --user)
    shift
    case "$1" in
      show-environment|daemon-reload|enable|restart) exit 0 ;;
      list-unit-files) exit 0 ;;
      status) echo "● orb-hermes.service - sandbox"; echo "   Active: active (running)"; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF

cat > "$SANDBOX/bin/crontab" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-" ] && cat >/dev/null
exit 0
EOF

cat > "$SANDBOX/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$SANDBOX/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# -n means "no password"; report failure so the installer prints its manual
# firewall instructions instead of pretending it opened the port.
[ "$1" = "-n" ] && exit 1
exit 0
EOF

cat > "$SANDBOX/bin/npm" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
# the ollama tag listing
for a in "$@"; do
  case "$a" in
    */api/tags)
      echo '{"models":[{"name":"qwen3.8-27b-hermes:latest","modified":"2026-11-11T00:00:00Z"}]}'
      exit 0 ;;
  esac
done
# anything else (health probes) -> a healthy-looking body
echo '{"ok": true, "hermes": "ollama", "stt": "unknown", "tts": "unknown"}'
exit 0
EOF

cat > "$SANDBOX/bin/python3" <<'EOF'
#!/usr/bin/env bash
# minimal python3 stand-in for the sandbox
if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
  target="${3:-}"
  mkdir -p "$target/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$target/bin/python"
  chmod +x "$target/bin/python"
  exit 0
fi
if [ "$1" = "-m" ] && [ "$2" = "pip" ]; then exit 0; fi
if [ "$1" = "-c" ]; then
  # the ollama model auto-detect script reads JSON on stdin
  cat >/dev/null 2>&1 || true
  echo "qwen3.8-27b-hermes:latest"
  exit 0
fi
exit 0
EOF

chmod +x "$SANDBOX/bin"/*
export PATH="$SANDBOX/bin:/usr/bin:/bin"
export HOME="$SANDBOX/home"

# ------------------------------------------------------------ run it
echo
echo "Running install.sh with --ollama-model"
bash "$BEELINK_DIR/install.sh" \
  --token sandbox-token-123 \
  --transport none \
  --wake orbit \
  --port 8787 \
  --ollama-model qwen3.8-27b-hermes:latest \
  >"$SANDBOX/install.log" 2>&1
rc=$?

echo
echo "--- assertions ---"
check "installer exited 0 (rc=$rc)"            "[ $rc -eq 0 ]"
check "token file written"                     "[ -f '$HOME/orb-hermes/TOKEN' ]"
check "token file has the token"               "[ \"\$(cat '$HOME/orb-hermes/TOKEN')\" = 'sandbox-token-123' ]"
check "bridge script installed"                "[ -f '$HOME/orb-hermes/run-bridge.sh' ]"
check "bridge script installed"                "[ -f '$HOME/orb-hermes/hermes_bridge.py' ]"
check "self-test script installed"             "[ -f '$HOME/orb-hermes/selftest-stt.py' ]"

# The decoder fix: PyAV 15+ dropped the 'metadata_errors' argument that
# faster-whisper still passes, so pinning av<15 has no wheel for python 3.14
# and breaks the install. The bridge reads the wav itself instead, so the
# installer must not pin av at all.
check "no PyAV pin in the installer"           "! grep -q 'av>=11' '$BEELINK_DIR/setup-beelink.sh'"
check "no PyAV pin in the fallback path"       "! grep -q 'av<15' '$BEELINK_DIR/setup-beelink.sh'"
check "faster-whisper installed on its own"    "grep -q 'pip install --quiet faster-whisper' '$BEELINK_DIR/setup-beelink.sh'"
check "the self-test is run"                   "grep -q 'selftest-stt.py' '$BEELINK_DIR/setup-beelink.sh'"
check "the bridge reads the wav itself"        "grep -q 'def load_audio' '$BEELINK_DIR/hermes_bridge.py'"
check "the worker uses the wav reader"         "grep -q 'model.transcribe(audio)' '$BEELINK_DIR/hermes_bridge.py'"
check "no bare path is handed to whisper"      "! grep -q 'model.transcribe(path)' '$BEELINK_DIR/hermes_bridge.py'"
check "the self-test uses the wav reader"      "grep -q 'bridge.load_audio(wav)' '$BEELINK_DIR/selftest-stt.py'"

RUN="$HOME/orb-hermes/run-bridge.sh"
check "OLLAMA_MODEL forwarded"                 "grep -q 'OLLAMA_MODEL=qwen3.8-27b-hermes:latest' '$RUN'"
check "OLLAMA_URL set"                         "grep -q 'OLLAMA_URL=http://127.0.0.1:11434' '$RUN'"
check "token exported"                         "grep -q 'BRIDGE_TOKEN=sandbox-token-123' '$RUN'"
check "port exported"                          "grep -q 'BRIDGE_PORT=8787' '$RUN'"
check "wake phrase exported"                   "grep -q 'WAKE_PHRASE=orbit' '$RUN'"
check "binds 0.0.0.0"                          "grep -q 'BRIDGE_HOST=0.0.0.0' '$RUN'"
check "systemd unit written"                   "[ -f '$HOME/.config/systemd/user/orb-hermes.service' ]"
check "tailscale NOT installed by default"     "! grep -q 'Installing Tailscale' '$SANDBOX/install.log'"
check "no tailscale setup attempted"           "! grep -q 'tailscale up' '$SANDBOX/install.log'"
check "LAN transport printed"                  "grep -q 'phone can reach the bridge on this LAN' '$SANDBOX/install.log'"

echo
echo "--- installer output (tail) ---"
tail -14 "$SANDBOX/install.log"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "ALL INSTALLER SANDBOX TESTS PASS"
  exit 0
fi
echo "$FAILS INSTALLER SANDBOX TEST(S) FAILED"
exit 1
