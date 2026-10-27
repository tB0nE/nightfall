#!/usr/bin/env bash
set -euo pipefail
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_JDK="${NIGHTFALL_JAVA_HOME:-${JAVA_HOME:-/home/linuxbrew/.linuxbrew/opt/openjdk@17}}"
TEST_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/home/linuxbrew/.linuxbrew/Caskroom/android-commandlinetools/15859902}}"
TEST_CLASSES="$(mktemp -d "${TMPDIR:-/tmp}/nightfall-blocker-jni.XXXXXXXX")"
TEST_ANDROID_JAR="$TEST_SDK/platforms/android-36/android.jar"
test -f "$TEST_ANDROID_JAR" || { echo "Set ANDROID_HOME to an SDK containing platforms/android-36/android.jar" >&2; exit 1; }
"${NIGHTFALL_CARGO:-$HOME/.cargo/bin/cargo}" build --locked --release --manifest-path "$TEST_ROOT/extensions/browser-adblock/Cargo.toml"
"$TEST_JDK/bin/javac" -encoding UTF-8 -cp "$TEST_ANDROID_JAR" -d "$TEST_CLASSES" \
    "$TEST_ROOT/android/src/main/java/com/godot/game/BrowserNavigation.java" \
    "$TEST_ROOT/android/src/main/java/com/godot/game/BrowserBlockingPolicy.java" \
    "$TEST_ROOT/android/src/main/java/com/godot/game/BrowserAdblock.java" \
    "$TEST_ROOT/test/java/com/godot/game/BrowserAdblockNativeTest.java"
"$TEST_JDK/bin/java" -cp "$TEST_CLASSES:$TEST_ANDROID_JAR" com.godot.game.BrowserAdblockNativeTest \
    "$TEST_ROOT/extensions/browser-adblock/target/release/libnightfall_browser_adblock.so" "$@"
