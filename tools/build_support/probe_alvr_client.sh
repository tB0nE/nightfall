#!/usr/bin/env bash
# Dependency/ABI spike only: never installs a driver, switches runtimes,
# packages an APK, starts SteamVR or advertises working PCVR support.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/alvr_xr_versions.sh"
source "$SCRIPT_DIR/native_xr_versions.sh"

MODE="${1:---check}"
if [[ "$MODE" != "--check" && "$MODE" != "--build" ]]; then
    echo "Usage: bash tools/build_support/probe_alvr_client.sh [--check|--build]" >&2
    exit 2
fi
CACHE="${NIGHTFALL_ALVR_CACHE:-$PROJECT_ROOT/.build-cache/meteor-xr}"
SOURCE="$CACHE/ALVR"
TOOLS="$CACHE/tools"
OUTPUT="$CACHE/artifacts/$NIGHTFALL_ALVR_VERSION/android-arm64"
ANDROID_HOME="${ANDROID_HOME:-/home/linuxbrew/.linuxbrew/share/android-commandlinetools}"
NDK="${ANDROID_NDK_ROOT:-$ANDROID_HOME/ndk/$NIGHTFALL_ANDROID_NDK_VERSION}"
LLVM="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"

echo "ALVR: v$NIGHTFALL_ALVR_VERSION ($NIGHTFALL_ALVR_COMMIT)"
echo "Cache: $CACHE"
echo "Android NDK: $NDK"
command -v cargo >/dev/null
command -v rustup >/dev/null
rustc --version
if ! rustup target list --installed | rg -qx aarch64-linux-android; then
    echo "Missing Rust target: rustup target add aarch64-linux-android" >&2
    exit 1
fi
if [[ ! -x "$LLVM/llvm-readelf" ]]; then
    echo "Android NDK tools missing; set ANDROID_NDK_ROOT." >&2
    exit 1
fi
for steam_root in "${XDG_DATA_HOME:-$HOME/.local/share}/Steam" \
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    if [[ -x "$steam_root/steamapps/common/SteamVR/bin/linux64/vrpathreg" ]]; then
        echo "SteamVR found: $steam_root/steamapps/common/SteamVR (not launched or registered)"
    fi
done
if [[ "$MODE" == "--check" ]]; then
    if [[ -d "$SOURCE/.git" ]]; then
        echo "Cached source revision: $(git -C "$SOURCE" rev-parse HEAD)"
    fi
    echo "Read-only toolchain preflight complete. Use --build to download/build the pinned core."
    exit 0
fi

mkdir -p "$CACHE" "$OUTPUT" "$TOOLS"
if [[ ! -d "$SOURCE/.git" ]]; then
    if [[ -e "$SOURCE" ]]; then
        echo "Refusing to overwrite non-checkout path: $SOURCE" >&2
        exit 1
    fi
    git clone --depth 1 --branch "v$NIGHTFALL_ALVR_VERSION" "$NIGHTFALL_ALVR_REPOSITORY" "$SOURCE"
fi
if [[ "$(git -C "$SOURCE" rev-parse HEAD)" != "$NIGHTFALL_ALVR_COMMIT" ]]; then
    echo "Cached ALVR revision does not match pin; refusing to build." >&2
    exit 1
fi
if [[ -n "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ]]; then
    echo "Cached ALVR tracked sources are modified; refusing an unrecorded ABI." >&2
    exit 1
fi
# alvr_session generates properties from the pinned OpenVR submodule even
# when only building the Android client core.
git -C "$SOURCE" submodule update --init --depth 1 openvr

if [[ ! -x "$TOOLS/bin/cargo-ndk" ]] || \
        ! cargo install --root "$TOOLS" --list | rg -q "^cargo-ndk v${NIGHTFALL_ALVR_CARGO_NDK_VERSION}:"; then
    cargo install --locked --root "$TOOLS" cargo-ndk --version "$NIGHTFALL_ALVR_CARGO_NDK_VERSION"
fi
if [[ ! -x "$TOOLS/bin/cbindgen" ]] || \
        [[ "$("$TOOLS/bin/cbindgen" --version)" != "cbindgen $NIGHTFALL_ALVR_CBINDGEN_VERSION" ]]; then
    cargo install --locked --root "$TOOLS" cbindgen --version "$NIGHTFALL_ALVR_CBINDGEN_VERSION"
fi

export PATH="$TOOLS/bin:$PATH"
export ANDROID_NDK_HOME="$NDK"
export ANDROID_NDK_ROOT="$NDK"
export CARGO_TARGET_DIR="$CACHE/target"
(
    cd "$SOURCE"
    cargo ndk --platform "$NIGHTFALL_ALVR_ANDROID_API" -t arm64-v8a -o "$OUTPUT" \
        build --locked --release --no-default-features -p alvr_client_core
)
HEADER="$OUTPUT/alvr_client_core.h"
(
    cd "$SOURCE/alvr/client_core"
    cbindgen --output "$HEADER"
)
LIBRARY="$OUTPUT/arm64-v8a/libalvr_client_core.so"
"$LLVM/llvm-readelf" -h "$LIBRARY"
"$LLVM/llvm-readelf" -d "$LIBRARY"
SYMBOLS="$("$LLVM/llvm-nm" --dynamic --defined-only "$LIBRARY")"
for symbol in alvr_initialize_android_context alvr_initialize alvr_destroy \
        alvr_resume alvr_pause alvr_poll_event alvr_send_tracking \
        alvr_send_view_params alvr_send_button alvr_initialize_opengl \
        alvr_start_stream_opengl alvr_render_stream_opengl alvr_create_decoder \
        alvr_get_frame alvr_report_compositor_start alvr_report_submit; do
    if ! rg -q "[[:space:]]${symbol}$" <<< "$SYMBOLS"; then
        echo "Required ALVR C API symbol missing: $symbol" >&2
        exit 1
    fi
done
# Compile the pinned interface/layout expectations with the extension's ABI.
"$LLVM/aarch64-linux-android$NIGHTFALL_ALVR_ANDROID_API-clang++" \
    -std=c++17 -fsyntax-only -I "$OUTPUT" "$PROJECT_ROOT/test/alvr_client_abi_probe.cpp"
"$LLVM/llvm-strip" --strip-debug "$LIBRARY" -o "$OUTPUT/arm64-v8a/libalvr_client_core.stripped.so"
cp "$SOURCE/LICENSE" "$OUTPUT/ALVR-LICENSE.txt"
(
    cd "$OUTPUT"
    sha256sum arm64-v8a/libalvr_client_core.so arm64-v8a/libalvr_client_core.stripped.so \
        alvr_client_core.h ALVR-LICENSE.txt > SHA256SUMS
)
echo "Pinned release core and C API verified: $OUTPUT"
echo "This does not prove XR session compatibility or a working stream. No host/device settings changed."
