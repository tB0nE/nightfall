#!/usr/bin/env bash
# Build only the bounded native sharing probe; does not install or run it.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
ndk_root="${ANDROID_NDK_HOME:-${ANDROID_HOME:-}/ndk/29.0.14206865}"
compiler="$ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang"
[[ -x "$compiler" ]] || { echo 'Set ANDROID_NDK_HOME or ANDROID_HOME for NDK r29.' >&2; exit 1; }
output="$repo_root/.build-cache/browser-quest-linux/kgsl-probe/gpu-buffer-probe"
mkdir -p "$(dirname "$output")"
"$compiler" -D_GNU_SOURCE -O2 -Wall -Wextra -Werror \
  "$repo_root/tools/experiments/browser-quest-linux/gpu-buffer-probe.c" \
  -o "$output" -lEGL -lGLESv2 -landroid
echo "$output"
