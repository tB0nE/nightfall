#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../../tools/build_support/native_xr_versions.sh
source "$PROJECT_ROOT/tools/build_support/native_xr_versions.sh"
TARGET="${1:-release}"
if [[ "$TARGET" != "release" && "$TARGET" != "debug" ]]; then
  echo "Usage: $0 [release|debug]" >&2
  exit 2
fi

NATIVE_XR_CACHE="${NIGHTFALL_NATIVE_XR_CACHE:-$PROJECT_ROOT/.build-cache/native-xr}"
NIGHTFALL_GODOT_SOURCE="${NIGHTFALL_GODOT_SOURCE:-$NATIVE_XR_CACHE/godot}"
NIGHTFALL_GODOT_CPP="${NIGHTFALL_GODOT_CPP:-$NATIVE_XR_CACHE/godot-cpp}"
ANDROID_HOME="${ANDROID_HOME:-/home/linuxbrew/.linuxbrew/share/android-commandlinetools}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_HOME/ndk/$NIGHTFALL_ANDROID_NDK_VERSION}"
JOBS="${NIGHTFALL_BUILD_JOBS:-$(nproc)}"

if [[ "$TARGET" == "release" ]]; then
  CMAKE_BUILD_TYPE="Release"
else
  CMAKE_BUILD_TYPE="Debug"
fi
GODOT_CPP_TARGET="template_$TARGET"
GODOT_CPP_SUFFIX=".android.$GODOT_CPP_TARGET.arm64"

if [[ ! -d "$NIGHTFALL_GODOT_SOURCE/thirdparty/openxr" ]]; then
  echo "Missing matching Godot source tree: $NIGHTFALL_GODOT_SOURCE" >&2
  echo "Run tools/build_support/bootstrap_native_xr.sh first." >&2
  exit 1
fi
if [[ ! -f "$NIGHTFALL_GODOT_CPP/extension_api.json" ]]; then
  echo "Missing OpenXR-inclusive godot-cpp API at $NIGHTFALL_GODOT_CPP/extension_api.json" >&2
  echo "Run tools/build_support/bootstrap_native_xr.sh first." >&2
  exit 1
fi

GODOT_CPP_LIB="$NIGHTFALL_GODOT_CPP/bin/libgodot-cpp$GODOT_CPP_SUFFIX.a"
if [[ ! -f "$GODOT_CPP_LIB" ]]; then
  scons -C "$NIGHTFALL_GODOT_CPP" platform=android target="$GODOT_CPP_TARGET" arch=arm64 \
    android_api_level=24 ndk_version="$NIGHTFALL_ANDROID_NDK_VERSION" \
    custom_api_file="$NIGHTFALL_GODOT_CPP/extension_api.json" -j"$JOBS"
fi

BUILD_DIR="$SCRIPT_DIR/build/android-$TARGET-arm64"
cmake -S "$SCRIPT_DIR" -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE="$CMAKE_BUILD_TYPE" \
  -DCMAKE_SYSTEM_NAME=Android \
  -DANDROID_ABI=arm64-v8a \
  -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
  -DCMAKE_ANDROID_NDK="$ANDROID_NDK_ROOT" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
  -DANDROID_PLATFORM=android-28 \
  -DGODOTCPP_CUSTOM_DIR="$NIGHTFALL_GODOT_CPP" \
  -DGODOT_SOURCE_DIR="$NIGHTFALL_GODOT_SOURCE" \
  -DOPENXR_INCLUDE_DIR="$NIGHTFALL_GODOT_SOURCE/thirdparty/openxr/include" \
  -DGODOTCPP_SUFFIX="$GODOT_CPP_SUFFIX"
cmake --build "$BUILD_DIR" -j "$JOBS"
