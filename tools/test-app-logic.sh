#!/usr/bin/env bash
# Compile and run the app's pure-Kotlin logic checks without an Android device.
#
# It uses the Kotlin compiler that is already in the Gradle cache, so it works
# offline. Covers the wake-word matcher and the WAV helpers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE="${GRADLE_USER_HOME:-$HOME/.gradle}/caches/modules-2/files-2.1"
# Gradle keeps a copy of the Kotlin compiler in its own lib folder. That is
# the fallback when the dependency cache has been cleared - the compiler is
# still there, so the checks still run offline.
GRADLE_LIB="${GRADLE_LIB:-$(ls -d /opt/homebrew/share/gradle-*/lib 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export JAVA_HOME="${JAVA_HOME:-$(ls -d /opt/homebrew/opt/openjdk@17 2>/dev/null | head -1)}"
export PATH="$JAVA_HOME/bin:$PATH"

find_jar() {
  # the cache may have been cleared - a missing folder is not an error here
  [ -d "$CACHE" ] || return 0
  find "$CACHE" -name "$1" 2>/dev/null | sort | head -1 || true
}

find_in_gradle() {
  [ -d "$GRADLE_LIB" ] || return 0
  find "$GRADLE_LIB" -name "$1" 2>/dev/null | sort | head -1 || true
}

# The org.jetbrains annotations are the ones the compiler understands. The
# com.android.tools artifact has the same file name, and putting that one on
# the classpath makes the compiler lose track of where a declaration came
# from - it then fails with "Backend Internal error" while lowering the code.
find_annotations() {
  if [ -d "$CACHE/org.jetbrains/annotations" ]; then
    find "$CACHE/org.jetbrains/annotations" -name "annotations-*.jar" 2>/dev/null | sort -r | head -1 || true
    return 0
  fi
  find_in_gradle 'annotations-*.jar'
}

# every jar has to be the same Kotlin version as the compiler
COMPILER="$(find_jar 'kotlin-compiler-embeddable-*.jar')"
if [ -z "$COMPILER" ]; then
    COMPILER="$(find_in_gradle 'kotlin-compiler-embeddable-*.jar')"
fi
if [ -n "$COMPILER" ]; then
    KV="$(basename "$COMPILER" | sed -E 's/kotlin-compiler-embeddable-(.*)\.jar/\1/')"
fi
STDLIB="$(find_jar "kotlin-stdlib-$KV.jar")"
if [ -z "$STDLIB" ]; then
    STDLIB="$(find_in_gradle "kotlin-stdlib-$KV.jar")"
fi
ANNOTATIONS="$(find_annotations)"
if [ -z "$ANNOTATIONS" ]; then
    ANNOTATIONS="$(find_in_gradle 'annotations-*.jar')"
fi
TROVE="$(find_jar 'trove4j-*.jar')"
if [ -z "$TROVE" ]; then
    TROVE="$(find_in_gradle 'trove4j-*.jar')"
fi
DAEMON="$(find_jar "kotlin-daemon-embeddable-$KV.jar")"
if [ -z "$DAEMON" ]; then
    DAEMON="$(find_in_gradle "kotlin-daemon-embeddable-$KV.jar")"
fi
SCRIPT_RT="$(find_jar "kotlin-script-runtime-$KV.jar")"
if [ -z "$SCRIPT_RT" ]; then
    SCRIPT_RT="$(find_in_gradle "kotlin-script-runtime-$KV.jar")"
fi
REFLECT="$(find_jar "kotlin-reflect-$KV.jar")"
if [ -z "$REFLECT" ]; then
    REFLECT="$(find_in_gradle "kotlin-reflect-$KV.jar")"
fi
COROUTINES="$(find_jar 'kotlinx-coroutines-core-jvm-*.jar')"
if [ -z "$COROUTINES" ]; then
    COROUTINES="$(find_in_gradle 'kotlinx-coroutines-core-jvm-*.jar')"
fi

if [[ -z "$COMPILER" || -z "$STDLIB" ]]; then
  echo "Kotlin compiler not found in the Gradle cache - run a Gradle build first." >&2
  exit 1
fi

CP="$COMPILER:$STDLIB:$ANNOTATIONS:$TROVE:$DAEMON:$SCRIPT_RT:$REFLECT:$COROUTINES"

cp "$ROOT/app/src/main/java/com/keith/orbhermes/WakeWord.kt" "$WORK/"
cp "$ROOT/app/src/main/java/com/keith/orbhermes/WavCodec.kt" "$WORK/"
cp "$ROOT/app/src/main/java/com/keith/orbhermes/ClipWindow.kt" "$WORK/"
cp "$ROOT/app/src/main/java/com/keith/orbhermes/BandSmoother.kt" "$WORK/"
cp "$ROOT/app/src/main/java/com/keith/orbhermes/AnswerCleaner.kt" "$WORK/"
cp "$ROOT/app/src/main/java/com/keith/orbhermes/UploadGuard.kt" "$WORK/"
cp "$ROOT/app/src/main/java/com/keith/orbhermes/Utterance.kt" "$WORK/"
cp "$ROOT/tools/wake-word-test/TestMain.kt" "$WORK/"
cp "$ROOT/tools/wake-word-test/CodecTest.kt" "$WORK/"
cp "$ROOT/tools/wake-word-test/ClipTest.kt" "$WORK/"
cp "$ROOT/tools/wake-word-test/BandTest.kt" "$WORK/"
cp "$ROOT/tools/wake-word-test/AnswerTest.kt" "$WORK/"
cp "$ROOT/tools/wake-word-test/GuardTest.kt" "$WORK/"
cp "$ROOT/tools/wake-word-test/UtteranceTest.kt" "$WORK/"

java -cp "$CP" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler \
  -cp "$STDLIB" "$WORK/WakeWord.kt" "$WORK/WavCodec.kt" "$WORK/ClipWindow.kt" \
  "$WORK/BandSmoother.kt" "$WORK/AnswerCleaner.kt" "$WORK/UploadGuard.kt" \
  "$WORK/Utterance.kt" \
  "$WORK/TestMain.kt" "$WORK/CodecTest.kt" "$WORK/ClipTest.kt" \
  "$WORK/BandTest.kt" "$WORK/AnswerTest.kt" "$WORK/GuardTest.kt" \
  "$WORK/UtteranceTest.kt" \
  -d "$WORK/out" 2>&1 |
  grep -viE '^warning:|^info:' || true

java -cp "$WORK/out:$STDLIB" TestMainKt
java -cp "$WORK/out:$STDLIB" CodecTestKt
java -cp "$WORK/out:$STDLIB" ClipTestKt
java -cp "$WORK/out:$STDLIB" BandTestKt
java -cp "$WORK/out:$STDLIB" AnswerTestKt
java -cp "$WORK/out:$STDLIB" GuardTestKt
java -cp "$WORK/out:$STDLIB" UtteranceTestKt
