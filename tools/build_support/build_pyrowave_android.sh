#!/usr/bin/env bash
set -euo pipefail

# Builds libpyrowave-shared.so for Android arm64-v8a and vendors it (plus
# its public header) into addons/nightfall-stream/third_party/pyrowave/.
#
# PyroWave (https://github.com/Themaister/pyrowave) ships no Android NDK
# cross-compile recipe of its own - build_aarch64.sh targets SteamOS/Steam
# Deck aarch64 Linux, and setup_android_build.sh generates a *standalone
# demo APK* via its own Granite engine's gradle generator, not a
# cross-compiled library artifact. This script builds just the
# `pyrowave-shared` CMake target directly against the Android NDK
# toolchain instead - a normal target once PYROWAVE_DEVEL/PYROWAVE_UTILS
# are left at their defaults (OFF), which routes Granite's own CMake logic
# to GRANITE_PLATFORM=null (no SDL, no runtime shader compiler, no
# renderer - see pyrowave's CMakeLists.txt's `elseif (${PROJECT_IS_TOP_LEVEL}
# ...)` branch). shaders/slangmosh.hpp (the Slang->SPIR-V shader codegen
# output `pyrowave-shared` compiles against) is pre-generated and checked
# into the pyrowave repo itself, so no Slang toolchain is needed here.
#
# The resulting .so is vendored as a prebuilt binary artifact (same pattern
# as addons/godotopenxrvendors's AAR or the LiteRT GPU AAR already in this
# repo) rather than rebuilt on every Nightfall build - it has nothing to do
# with Nightfall's own source and changes only when PyroWave itself does.
#
# Usage: bash tools/build_support/build_pyrowave_android.sh
# Requires: ANDROID_NDK_HOME set to an NDK install (tested against r29,
# 29.0.14206865 - matches addons/nightfall-stream's own NDK version).

PYROWAVE_COMMIT="${NIGHTFALL_PYROWAVE_COMMIT:-89f7e47d4abbf650c91fae766728af866c5e32a0}"
# Pinned by pyrowave's own checkout_granite.sh at the commit above.
GRANITE_COMMIT="1b2d1801d2910fb09ebcded2f0bb3a3a781103b5"

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
VENDOR_DIR="$PROJECT_ROOT/addons/nightfall-stream/third_party/pyrowave"
WORK_DIR="${NIGHTFALL_PYROWAVE_WORKDIR:-$PROJECT_ROOT/.build-cache/pyrowave-src}"

: "${ANDROID_NDK_HOME:?Set ANDROID_NDK_HOME to an NDK install (e.g. 29.0.14206865)}"
ANDROID_ABI="arm64-v8a"
ANDROID_PLATFORM="android-28"

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ ! -d pyrowave ]; then
  git clone https://github.com/Themaister/pyrowave.git
fi
cd pyrowave
git fetch origin
git checkout "$PYROWAVE_COMMIT"

if [ ! -d Granite ]; then
  git clone https://github.com/Themaister/Granite
fi
(cd Granite && git fetch origin && git checkout "$GRANITE_COMMIT")
(cd Granite && git submodule sync third_party/volk third_party/khronos/vulkan-headers \
  && git submodule update --init third_party/volk third_party/khronos/vulkan-headers)

cmake -S . -B build-android -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$ANDROID_ABI" -DANDROID_PLATFORM="$ANDROID_PLATFORM" \
  -DCMAKE_BUILD_TYPE=Release

ninja -C build-android pyrowave-shared

mkdir -p "$VENDOR_DIR/include" "$VENDOR_DIR/lib/android-$ANDROID_ABI"
"$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" --strip-debug \
  build-android/libpyrowave-shared.so \
  -o "$VENDOR_DIR/lib/android-$ANDROID_ABI/libpyrowave-shared.so"
cp pyrowave.h "$VENDOR_DIR/include/pyrowave.h"
# pyrowave.h uses Vulkan types directly without including the Vulkan headers
# itself. The NDK ships its own (older) copy of vulkan/vulkan.h, which is
# missing types PyroWave was actually built against (e.g.
# VkQueueGlobalPriority) - vendor the exact pinned Vulkan-Headers tree
# Granite itself used so consumers get a header-compatible <vulkan/vulkan.h>
# ahead of the NDK's on the include path, rather than a silent ABI mismatch.
rm -rf "$VENDOR_DIR/include/vulkan" "$VENDOR_DIR/include/vk_video"
cp -r Granite/third_party/khronos/vulkan-headers/include/vulkan "$VENDOR_DIR/include/vulkan"
cp -r Granite/third_party/khronos/vulkan-headers/include/vk_video "$VENDOR_DIR/include/vk_video"

cat > "$VENDOR_DIR/VERSION" <<EOF
pyrowave: $PYROWAVE_COMMIT
Granite: $GRANITE_COMMIT
built: $(date -u +%Y-%m-%dT%H:%M:%SZ)
ndk: $(basename "$ANDROID_NDK_HOME")
abi: $ANDROID_ABI
platform: $ANDROID_PLATFORM
EOF

echo "Vendored $(ls -la "$VENDOR_DIR/lib/android-$ANDROID_ABI/libpyrowave-shared.so" | awk '{print $5}') bytes to $VENDOR_DIR"
