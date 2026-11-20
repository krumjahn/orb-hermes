#!/usr/bin/env bash
# Build the Orb Hermes APK and push it to the attached phone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

# The JDK, the Android SDK and Gradle are all found rather than hardcoded.
if [ -z "${JAVA_HOME:-}" ]; then
  for candidate in /opt/homebrew/opt/openjdk@17 /usr/libexec/java_home /usr/local/opt/openjdk@17; do
    if [ -x "$candidate" ]; then JAVA_HOME="$candidate"; break; fi
    if [ -x "$candidate/bin/java" ]; then JAVA_HOME="$candidate"; break; fi
  done
fi
[ -n "${JAVA_HOME:-}" ] && export JAVA_HOME

if [ -z "${ANDROID_HOME:-}" ] && [ -n "${ANDROID_SDK_ROOT:-}" ]; then
  ANDROID_HOME="$ANDROID_SDK_ROOT"
fi
if [ -z "${ANDROID_HOME:-}" ]; then
  for candidate in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [ -d "$candidate" ] && ANDROID_HOME="$candidate" && break
  done
fi
[ -n "${ANDROID_HOME:-}" ] && export ANDROID_HOME
[ -n "${ANDROID_HOME:-}" ] && export PATH="$ANDROID_HOME/platform-tools:$PATH"

if [ -z "${GRADLE:-}" ]; then
  if command -v gradle >/dev/null 2>&1; then
    GRADLE="$(command -v gradle)"
  else
    GRADLE="$(ls /opt/homebrew/share/gradle-*/bin/gradle 2>/dev/null | sort -V | tail -1)"
  fi
fi
if [ -z "$GRADLE" ] || [ ! -x "$GRADLE" ]; then
  echo "==> no Gradle found. Install Gradle 8.x, or set GRADLE=/path/to/gradle" >&2
  exit 1
fi

# the device is whatever adb reports, unless one is named explicitly
if [ -z "${DEVICE:-}" ]; then
  DEVICE="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1; exit}')"
fi
if [ -z "${DEVICE:-}" ]; then
  echo "==> no device found. Plug the phone in, or set DEVICE=<serial>" >&2
  exit 1
fi

cd "$ROOT"
if [[ "${RELEASE:-0}" == "1" ]]; then
  "$GRADLE" assembleRelease --console=plain "$@"
  APK="$ROOT/app/build/outputs/apk/release/app-release.apk"
else
  "$GRADLE" assembleDebug --console=plain "$@"
  APK="$ROOT/app/build/outputs/apk/debug/app-debug.apk"
fi
echo "==> APK: $APK ($(du -h "$APK" | cut -f1))"

adb -s "$DEVICE" install -r "$APK"
adb -s "$DEVICE" shell am force-stop com.keith.orbhermes
adb -s "$DEVICE" shell am start -n com.keith.orbhermes/.MainActivity >/dev/null
echo "==> launched on $DEVICE"
