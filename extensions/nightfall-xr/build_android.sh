#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-release}"
if [[ "$TARGET" != "release" && "$TARGET" != "debug" ]]; then
  echo "Usage: $0 [release|debug]" >&2
  exit 2
fi

NIGHTFALL_GODOT_SOURCE="${NIGHTFALL_GODOT_SOURCE:-/tmp/nightfall-godot-sharpen}"
NIGHTFALL_GODOT_CPP="${NIGHTFALL_GODOT_CPP:-/tmp/godot-cpp-custom}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-/home/linuxbrew/.linuxbrew/share/android-commandlinetools/ndk/29.0.14206865}"
JOBS="${NIGHTFALL_BUILD_JOBS:-$(nproc)}"

if [[ ! -d "$NIGHTFALL_GODOT_SOURCE/thirdparty/openxr" ]]; then
  echo "Missing matching Godot source tree: $NIGHTFALL_GODOT_SOURCE" >&2
  exit 1
fi
if [[ ! -f "$NIGHTFALL_GODOT_CPP/extension_api.json" ]]; then
  echo "Missing OpenXR-inclusive godot-cpp API at $NIGHTFALL_GODOT_CPP/extension_api.json" >&2
  echo "Generate it with the matching patched Godot editor using --dump-extension-api --dump-gdextension-interface." >&2
  exit 1
fi

GODOT_CPP_LIB="$NIGHTFALL_GODOT_CPP/bin/libgodot-cpp.android.template_release.arm64.a"
if [[ ! -f "$GODOT_CPP_LIB" ]]; then
  scons -C "$NIGHTFALL_GODOT_CPP" platform=android target=template_release arch=arm64 \
    android_api_level=21 custom_api_file="$NIGHTFALL_GODOT_CPP/extension_api.json" -j"$JOBS"
fi

BUILD_DIR="$SCRIPT_DIR/build/android-release-arm64"
cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=Android \
  -DANDROID_ABI=arm64-v8a \
  -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
  -DCMAKE_ANDROID_NDK="$ANDROID_NDK_ROOT" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
  -DANDROID_PLATFORM=android-28 \
  -DGODOTCPP_CUSTOM_DIR="$NIGHTFALL_GODOT_CPP" \
  -DGODOT_SOURCE_DIR="$NIGHTFALL_GODOT_SOURCE" \
  -DGODOTCPP_SUFFIX=.android.template_release.arm64
cmake --build "$BUILD_DIR" -j "$JOBS"
