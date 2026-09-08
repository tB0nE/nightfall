#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="${NIGHTFALL_TEST_BUILD_ROOT:-${TMPDIR:-/tmp}/nightfall-native-tests}"
CXX="${CXX:-c++}"

if ! command -v pkg-config >/dev/null 2>&1; then
  echo "pkg-config is required for the native unit tests" >&2
  exit 1
fi

if ! pkg-config --exists libavcodec libavutil; then
  LOCAL_PKGCONFIG="$PROJECT_ROOT/addons/nightfall-stream/build/linux-release/vcpkg_installed/x64-linux/lib/pkgconfig"
  if [[ -d "$LOCAL_PKGCONFIG" ]]; then
    export PKG_CONFIG_PATH="$LOCAL_PKGCONFIG${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  fi
fi
if ! pkg-config --exists libavcodec libavutil; then
  echo "FFmpeg development packages (libavcodec and libavutil) are required" >&2
  exit 1
fi

mkdir -p "$BUILD_ROOT"
echo "Building decode_unit_queue_test"
# Word splitting is intentional for compiler and linker flags from pkg-config.
# shellcheck disable=SC2046
"$CXX" -std=c++17 -Wall -Wextra -Werror \
  $(pkg-config --cflags libavcodec libavutil) \
  "$PROJECT_ROOT/test/decode_unit_queue_test.cpp" \
  -I"$PROJECT_ROOT/addons/nightfall-stream/src" \
  $(pkg-config --libs libavcodec libavutil) \
  -o "$BUILD_ROOT/decode_unit_queue_test"

"$BUILD_ROOT/decode_unit_queue_test"
echo "All native unit tests passed"
