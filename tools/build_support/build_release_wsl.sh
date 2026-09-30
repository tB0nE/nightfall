#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE_ROOT="$PROJECT_ROOT/.build-cache"

if [[ ! -f "$CACHE_ROOT/native-xr/templates/4.7.stable/android_release_arm64.so" ]]; then
  echo "Missing patched release runtime in $CACHE_ROOT/native-xr" >&2
  exit 1
fi
if [[ ! -f "$CACHE_ROOT/android-sdk/ndk/29.0.14206865/build/cmake/android.toolchain.cmake" ]]; then
  echo "Missing Android NDK 29.0.14206865 in $CACHE_ROOT/android-sdk" >&2
  exit 1
fi
if [[ ! -x "$CACHE_ROOT/godot/editor/Godot_v4.7-stable_linux.x86_64" ]]; then
  echo "Missing Godot 4.7 editor in $CACHE_ROOT/godot/editor" >&2
  exit 1
fi
if [[ ! -x "$CACHE_ROOT/platform-tools/adb.exe" ]]; then
  echo "Missing Windows adb.exe in $CACHE_ROOT/platform-tools" >&2
  exit 1
fi

# Keep the paths used by the cached native build stable across WSL restarts.
if [[ ! -e /tmp/nightfall-native-xr && ! -L /tmp/nightfall-native-xr ]]; then
  ln -s "$CACHE_ROOT/native-xr" /tmp/nightfall-native-xr
fi
if [[ ! -e /tmp/nightfall-sdk && ! -L /tmp/nightfall-sdk ]]; then
  ln -s "$CACHE_ROOT/android-sdk" /tmp/nightfall-sdk
fi

export NIGHTFALL_GODOT_EDITOR="$CACHE_ROOT/godot/editor/Godot_v4.7-stable_linux.x86_64"
export NIGHTFALL_NATIVE_XR_CACHE=/tmp/nightfall-native-xr
export NIGHTFALL_BUILD_JOBS="${NIGHTFALL_BUILD_JOBS:-8}"
export ANDROID_HOME=/tmp/nightfall-sdk
export ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/29.0.14206865"
export NIGHTFALL_JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export XDG_DATA_HOME="$CACHE_ROOT"
export XDG_CONFIG_HOME="$CACHE_ROOT/xdg-config"
export XDG_CACHE_HOME="$CACHE_ROOT/xdg-cache"
export GRADLE_USER_HOME="$CACHE_ROOT/gradle"

cd "$PROJECT_ROOT"
./build.sh --release
"$CACHE_ROOT/platform-tools/adb.exe" install -r "$PROJECT_ROOT/Nightfall-Android-arm64-v8a.apk"
