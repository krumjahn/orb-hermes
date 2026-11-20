#!/usr/bin/env bash
# Wait for the Beelink's firewall to open TCP 8787, then verify the whole
# phone -> bridge -> model chain from the phone itself.
set -uo pipefail

TOKEN="YOUR_BRIDGE_TOKEN"
BEELINK="192.168.1.20:8787"
export PATH="${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools:$PATH"

echo "[watch] waiting for http://$BEELINK/health to answer..."
for i in $(seq 1 280); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 \
      -H "X-Auth-Token: $TOKEN" "http://$BEELINK/health" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then
    echo "[watch] PORT OPEN after ~$((i * 10))s"

    echo
    echo "=== 1. /health from the Mac ==="
    curl -s --max-time 8 -H "X-Auth-Token: $TOKEN" "http://$BEELINK/health"; echo

    echo
    echo "=== 2. /health from the PHONE (over Wi-Fi) ==="
    adb -s DEVICE_SERIAL shell "/system/bin/curl -s --max-time 10 -H 'X-Auth-Token: $TOKEN' http://$BEELINK/health" 2>&1; echo

    echo
    echo "=== 3. /chat from the PHONE ==="
    adb -s DEVICE_SERIAL shell "/system/bin/curl -s --max-time 40 -X POST http://$BEELINK/chat -H 'X-Auth-Token: $TOKEN' -H 'Content-Type: application/json' -d '{\"text\":\"Reply with exactly: ORB_LAN_OK\"}'" 2>&1; echo

    echo
    echo "=== 4. /tts from the PHONE ==="
    adb -s DEVICE_SERIAL shell "/system/bin/curl -s --max-time 40 -o /dev/null -w 'tts:%{http_code} bytes:%{size_download}\n' -X POST http://$BEELINK/tts -H 'X-Auth-Token: $TOKEN' -H 'Content-Type: application/json' -d '{\"text\":\"Hello from the Beelink.\"}'" 2>&1; echo

    echo
    echo "=== 5. /stt from the PHONE (empty wav, proves the speech chain) ==="
    adb -s DEVICE_SERIAL push /tmp/probe.wav /sdcard/probe.wav >/dev/null 2>&1
    adb -s DEVICE_SERIAL shell "/system/bin/curl -s --max-time 60 -X POST http://$BEELINK/stt -H 'X-Auth-Token: $TOKEN' --data-binary @/sdcard/probe.wav" 2>&1; echo

    echo
    echo "=== 6. app health poll ==="
    adb -s DEVICE_SERIAL logcat -d -s OrbHermes:* 2>/dev/null | tail -8
    exit 0
  fi
  sleep 10
done

echo "[watch] TIMEOUT: the port never opened within ~47 minutes"
exit 1
