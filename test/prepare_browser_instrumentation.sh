#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Prepare only. Never install or run tests over the user's app/profile.
test -f android/build/gradlew || { echo 'First run ./build.sh --dev to prepare the Android export.' >&2; exit 1; }
mkdir -p android/build/src/instrumented/java/com/godot/game android/build/src/androidTest/java/com/godot/game
cp android/src/instrumented/AndroidManifest.xml android/build/src/instrumented/AndroidManifest.xml
cp android/src/instrumented/java/com/godot/game/BrowserTestActivity.java android/build/src/instrumented/java/com/godot/game/
cp android/src/androidTest/java/com/godot/game/BrowserWebViewIntegrationTest.java android/build/src/androidTest/java/com/godot/game/
echo 'Prepared isolated instrumented flavor. Review docs/plans/active/browser-testing.md before running.'
