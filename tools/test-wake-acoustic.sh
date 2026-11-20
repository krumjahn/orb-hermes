#!/usr/bin/env bash
#
# test-wake-acoustic.sh - play the wake phrase out loud on the Mac and watch
# the phone react to it. Requires the Mac's audio output to work and the
# phone to be on the same Wi-Fi as the bridge.
#
set -uo pipefail
export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"
DEVICE="${DEVICE:-$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1; exit}')}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# The phrase has to come out of the built-in speakers. A Bluetooth headset
# that reconnects steals the default output, and its codec mangles the
# consonants of "Orbit" into something the transcriber never recovers.
SWITCHER="/tmp/orb-audioswitch"
if [ ! -x "$SWITCHER" ]; then
  /usr/bin/swiftc "$HERE/audioswitch.swift" -o "$SWITCHER" 2>/dev/null
fi
if [ -x "$SWITCHER" ]; then
  "$SWITCHER" "${OUTPUT_DEVICE:-Built-in Speakers}" | tail -1
fi
osascript -e 'set volume output volume 100' >/dev/null 2>&1
osascript -e 'set volume output muted false' >/dev/null 2>&1
echo "[test] output: $("$SWITCHER" 2>/dev/null | grep default)"

echo "[test] building the wake phrase audio..."
say -v Samantha -o /tmp/wake_raw.aiff "Orbit, what time is it" || exit 1
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/wake_raw.aiff /tmp/wake_raw.wav || exit 1

# 0.8s silence, then the phrase, then a 0.5s gap, then the phrase again
python3 - <<'PY'
import wave, struct
src = wave.open('/tmp/wake_raw.wav', 'rb')
n = src.getnframes(); raw = src.readframes(n); src.close()
sil = b'\x00\x00' * int(16000 * 0.8)
gap = b'\x00\x00' * int(16000 * 0.5)
out = wave.open('/tmp/wake_spaced.wav', 'wb')
out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000)
out.writeframes(sil + raw + gap + raw)
out.close()
print("[test] /tmp/wake_spaced.wav ready")
PY

echo "[test] clearing logcat..."
adb -s "$DEVICE" logcat -c 2>/dev/null

echo "[test] playing through the Mac's speakers (3s)..."
afplay /tmp/wake_spaced.wav 2>&1 &
AUDIO_PID=$!

for i in $(seq 1 24); do
  sleep 1
  HIT="$(adb -s "$DEVICE" logcat -d -s OrbHermes:* 2>/dev/null | grep -E 'wake: heard=|utterance:|recovered utterance:|mic level=' | tail -5)"
  if [ -n "$HIT" ]; then
    echo
    echo "=== WAKE TEST ACTIVITY (after ${i}s) ==="
    echo "$HIT"
    break
  fi
done

wait $AUDIO_PID 2>/dev/null
sleep 12   # let the model answer and the bridge speak

echo
echo "=== FULL ORB LOG ==="
adb -s "$DEVICE" logcat -d -s OrbHermes:* 2>/dev/null | grep -vE "fps=" | tail -40

echo
echo "=== app status ==="
adb -s "$DEVICE" shell dumpsys activity activities 2>/dev/null | grep -m1 "mResumedActivity" || true
