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

# Working copies live on the WSL filesystem: builds over the Windows mount are
# slow, and systemd empties /tmp on every WSL boot. The CMake build tree has
# the /tmp/nightfall-* paths baked in, so those are kept as symlinks into it.
WSL_CACHE="${NIGHTFALL_WSL_CACHE:-$HOME/.cache/nightfall-build}"
mkdir -p "$WSL_CACHE"

# stable_path NAME SEED: point /tmp/nightfall-NAME at $WSL_CACHE/NAME, adopting
# an existing real /tmp directory or copying SEED when the working copy is gone.
stable_path() {
  local link="/tmp/nightfall-$1" target="$WSL_CACHE/$1" seed="${2:-}"
  if [[ -d "$link" && ! -L "$link" ]]; then
    if [[ -e "$target" ]]; then
      echo "Both $link and $target exist; remove one of them" >&2
      exit 1
    fi
    mv "$link" "$target"
  elif [[ ! -e "$target" ]]; then
    if [[ -n "$seed" ]]; then
      echo "Copying $seed to $target (one-time)"
      cp -a "$seed" "$target"
    else
      mkdir -p "$target"
    fi
  fi
  ln -sfn "$target" "$link"
}
stable_path native-xr "$CACHE_ROOT/native-xr"
stable_path sdk "$CACHE_ROOT/android-sdk"
stable_path vcpkg "$CACHE_ROOT/vcpkg"
stable_path stream-build

export NIGHTFALL_GODOT_EDITOR="$CACHE_ROOT/godot/editor/Godot_v4.7-stable_linux.x86_64"
export NIGHTFALL_NATIVE_XR_CACHE=/tmp/nightfall-native-xr
export NIGHTFALL_BUILD_JOBS="${NIGHTFALL_BUILD_JOBS:-8}"
export ANDROID_HOME=/tmp/nightfall-sdk
export ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/29.0.14206865"
# vcpkg's arm64-android triplet locates the NDK through ANDROID_NDK_HOME.
export ANDROID_NDK_HOME="$ANDROID_NDK_ROOT"
export NIGHTFALL_JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export XDG_DATA_HOME="$CACHE_ROOT"
export XDG_CONFIG_HOME="$CACHE_ROOT/xdg-config"
export XDG_CACHE_HOME="$CACHE_ROOT/xdg-cache"
export GRADLE_USER_HOME="$CACHE_ROOT/gradle"

cd "$PROJECT_ROOT"

# build.sh packages the prebuilt streaming GDExtension but does not build it.
STREAM_BUILD=/tmp/nightfall-stream-build
STREAM_SO=libnightfall-stream.android.template_release.arm64.so
if [[ ! -f "$STREAM_BUILD/build.ninja" ]]; then
  cmake -S addons/nightfall-stream -B "$STREAM_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE=/tmp/nightfall-vcpkg/scripts/buildsystems/vcpkg.cmake \
    -DVCPKG_TARGET_TRIPLET=arm64-android \
    -DVCPKG_CHAINLOAD_TOOLCHAIN_FILE="$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" \
    -DCMAKE_SYSTEM_NAME=Android \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-28 \
    -DNIGHTFALL_PLATFORM=android \
    -DCMAKE_COMPILE_WARNING_AS_ERROR=FALSE
fi
ninja -C "$STREAM_BUILD" -j "$NIGHTFALL_BUILD_JOBS"
"$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip" --strip-debug \
  "$STREAM_BUILD/bin/android/$STREAM_SO" -o "addons/nightfall-stream/bin/android/$STREAM_SO"

./build.sh --release
# adb.exe is a Windows binary, so it needs a Windows path to the APK.
"$CACHE_ROOT/platform-tools/adb.exe" install -r "$(wslpath -w "$PROJECT_ROOT/Nightfall-Android-arm64-v8a.apk")"
