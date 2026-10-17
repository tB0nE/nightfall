#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_JAVA_HOME="${NIGHTFALL_JAVA_HOME:-${JAVA_HOME:-/home/linuxbrew/.linuxbrew/opt/openjdk@17}}"
TEST_CLASSES="$(mktemp -d "${TMPDIR:-/tmp}/nightfall-browser-navigation.XXXXXXXX")"

# Keep the small compiled test directory in /tmp for inspection; never write
# generated Java classes into the source tree. Requires JDK 17, not Android.
"$TEST_JAVA_HOME/bin/javac" -encoding UTF-8 -d "$TEST_CLASSES" \
    "$PROJECT_ROOT/android/src/main/java/com/godot/game/BrowserNavigation.java" \
    "$PROJECT_ROOT/android/src/main/java/com/godot/game/BrowserPageTabs.java" \
    "$SCRIPT_DIR/java/com/godot/game/BrowserPageTabsTest.java" \
    "$PROJECT_ROOT/android/src/main/java/com/godot/game/BrowserBookmarks.java" \
    "$PROJECT_ROOT/android/src/main/java/com/godot/game/BrowserHistory.java" \
    "$PROJECT_ROOT/android/src/main/java/com/godot/game/BrowserBlockingPolicy.java" \
    "$PROJECT_ROOT/android/src/main/java/com/godot/game/BrowserGamepadProbe.java" \
    "$PROJECT_ROOT/android/src/main/java/com/godot/game/BrowserGamepadState.java" \
    "$PROJECT_ROOT/android/src/main/java/com/godot/game/BrowserGamepadScript.java" \
    "$SCRIPT_DIR/java/com/godot/game/BrowserGamepadTest.java" \
    "$SCRIPT_DIR/java/com/godot/game/BrowserIntegrationTest.java" \
    "$SCRIPT_DIR/java/com/godot/game/BrowserNavigationTest.java" \
    "$SCRIPT_DIR/java/com/godot/game/BrowserBookmarksTest.java" \
    "$SCRIPT_DIR/java/com/godot/game/BrowserBlockingPolicyTest.java" \
    "$SCRIPT_DIR/java/com/godot/game/BrowserHistoryTest.java"
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.godot.game.BrowserNavigationTest
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.godot.game.BrowserPageTabsTest
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.godot.game.BrowserBookmarksTest
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.godot.game.BrowserBlockingPolicyTest
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.godot.game.BrowserHistoryTest
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.godot.game.BrowserIntegrationTest
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.godot.game.BrowserGamepadTest
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.godot.game.BrowserGamepadTest --script > "$TEST_CLASSES/gamepad.js"
"$TEST_JAVA_HOME/bin/java" -cp "$TEST_CLASSES" com.godot.game.BrowserGamepadTest --state > "$TEST_CLASSES/gamepad.json"
node "$SCRIPT_DIR/browser_gamepad_script_test.cjs" "$TEST_CLASSES/gamepad.js" "$TEST_CLASSES/gamepad.json"
