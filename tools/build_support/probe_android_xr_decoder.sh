#!/usr/bin/env bash
# Decoder-only device test through ADB. Does not launch/change the Nightfall app.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
source "$TOOL_DIR/native_xr_versions.sh"
SDK_ROOT="${ANDROID_HOME:-/home/linuxbrew/.linuxbrew/share/android-commandlinetools}"
NDK_ROOT="$SDK_ROOT/ndk/$NIGHTFALL_ANDROID_NDK_VERSION"
ADB="${NIGHTFALL_ADB:-adb}"
OUT="$ROOT/.build-cache/meteor-xr/android-decoder-spike"
FRAMES="${NIGHTFALL_XR_PROBE_FRAMES:-32}"
[[ "$FRAMES" =~ ^[0-9]+$ ]] && (( FRAMES >= 1 && FRAMES <= 240 ))
mkdir -p "$OUT"
"$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android32-clang++" \
    -std=c++17 -O2 -Wall -Wextra -Werror -static-libstdc++ \
    -I "$ROOT/extensions/nightfall-xr/include" \
    "$ROOT/test/pcvr_meteor_decoder_device_test.cpp" "$ROOT/extensions/nightfall-xr/src/pcvr_meteor_receiver.cpp" \
    -lmediandk -landroid -llog -o "$OUT/decoder-probe"
"$ADB" push "$OUT/decoder-probe" /data/local/tmp/nightfall-xr-decoder-probe
"$ADB" shell chmod 700 /data/local/tmp/nightfall-xr-decoder-probe
PORT="$("$ADB" forward tcp:0 tcp:49090)"
[[ "$PORT" =~ ^[0-9]+$ ]]
TEST_PID=""
cleanup() {
    if [[ -n "$TEST_PID" ]]; then kill "$TEST_PID" 2>/dev/null || true; wait "$TEST_PID" 2>/dev/null || true; fi
    "$ADB" forward --remove "tcp:$PORT" >/dev/null 2>&1 || true
}
trap cleanup EXIT
"$ADB" shell timeout 38s /data/local/tmp/nightfall-xr-decoder-probe "$FRAMES" > "$OUT/device.log" 2>&1 &
TEST_PID=$!
READY=0
for attempt in {1..100}; do
    if rg -q '^READY' "$OUT/device.log"; then READY=1; break; fi
    kill -0 "$TEST_PID" || { tail -20 "$OUT/device.log"; exit 1; }
    sleep 0.05
done
[[ "$READY" == 1 ]] || { tail -20 "$OUT/device.log"; exit 1; }
NIGHTFALL_XR_DEVICE_PORT="$PORT" NIGHTFALL_XR_PROBE_FRAMES="$FRAMES" \
    bash "$TOOL_DIR/probe_monado_nvenc.sh"
wait "$TEST_PID"
TEST_PID=""
tail -4 "$OUT/device.log"
