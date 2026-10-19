#!/usr/bin/env bash
# USB-only live tracking -> Monado -> pattern encode/decode test.
# A tiny CPU-reference scene, hardware encoded, with explicit render-space poses.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
ADB="${NIGHTFALL_ADB:-adb}"
OUT="$ROOT/.build-cache/meteor-xr/headset-tracking-runtime-spike"
mkdir -p "$OUT"
VIDEO_PORT=""
TRACKING_PORT=""
LOG_PID=""
if [[ "${NIGHTFALL_XR_TOUCH_INPUTS:-0}" == 1 ]]; then
    export NIGHTFALL_XR_INPUT_SECONDS="${NIGHTFALL_XR_INPUT_SECONDS:-30}"
    export NIGHTFALL_XR_PROBE_FRAMES="${NIGHTFALL_XR_PROBE_FRAMES:-240}"
fi
cleanup() {
    if [[ -n "$LOG_PID" ]]; then kill "$LOG_PID" 2>/dev/null || true; wait "$LOG_PID" 2>/dev/null || true; fi
    if [[ -n "$VIDEO_PORT" ]]; then "$ADB" forward --remove "tcp:$VIDEO_PORT" >/dev/null 2>&1 || true; fi
    if [[ -n "$TRACKING_PORT" ]]; then "$ADB" forward --remove "tcp:$TRACKING_PORT" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
VIDEO_PORT="$("$ADB" forward tcp:0 tcp:49090)"
TRACKING_PORT="$("$ADB" forward tcp:0 tcp:49091)"
[[ "$VIDEO_PORT" =~ ^[0-9]+$ && "$TRACKING_PORT" =~ ^[0-9]+$ ]]
"$ADB" logcat -T 1 -v brief -s NightfallPCVR:I > "$OUT/device.log" 2>&1 &
LOG_PID=$!
if [[ "${NIGHTFALL_XR_HELLO_XR:-0}" == 1 ]]; then
    echo 'Fixture armed. Tap DEV: Meteor decoded stereo. Expect Khronos hello_xr reference-space cubes on a plain background; gently move your head.'
elif [[ "${NIGHTFALL_XR_RASTER_SCENE:-0}" == 1 ]]; then
    echo 'Fixture armed. Tap DEV: Meteor decoded stereo. Expect rotating colored cubes and a checkerboard floor; gently move your head.'
else
    echo 'Fixture armed. Tap DEV: Meteor decoded stereo. Expect three colored spheres and a floor; gently move your head.'
fi
echo "Profile: ${NIGHTFALL_XR_EYE_SIZE:-256}x${NIGHTFALL_XR_EYE_SIZE:-256} per eye, target ${NIGHTFALL_XR_TARGET_HZ:-20} Hz; actual timings are recorded separately."
if [[ "${NIGHTFALL_XR_TOUCH_INPUTS:-0}" == 1 ]]; then
    echo "Input test: ${NIGHTFALL_XR_INPUT_SECONDS}s, deliberately paced. Stick moves marker; X/A widens hand cube; stick click makes it taller; grip changes size."
    if [[ "${NIGHTFALL_XR_HAPTICS:-0}" == 1 ]]; then
        echo 'Haptics: fully squeeze each grip separately; expect a short rumble in that controller only.'
    fi
fi
READY=0
for attempt in {1..1200}; do
    if rg -q 'Meteor projection receiver requested' "$OUT/device.log" && rg -q 'Listening on loopback :49090' "$OUT/device.log"; then READY=1; break; fi
    kill -0 "$LOG_PID" || { tail -20 "$OUT/device.log"; exit 1; }
    sleep 0.05
done
[[ "$READY" == 1 ]] || { echo 'No projection test started within 60 seconds' >&2; exit 1; }
NIGHTFALL_XR_DEVICE_PORT="$VIDEO_PORT" NIGHTFALL_XR_TRACKING_PORT="$TRACKING_PORT" \
    METEOR_XR_TRACKED_SCENE=1 \
    NIGHTFALL_XR_PROBE_FRAMES="${NIGHTFALL_XR_PROBE_FRAMES:-120}" \
    bash "$TOOL_DIR/probe_monado_nvenc.sh"
rg -q 'METEOR DECODED.*first frame: ONE projection layer' "$OUT/device.log"
rg -q 'METEOR TRACKED SCENE: host render poses/FOV mapped' "$OUT/device.log"
echo 'Scene delivered with live headset tracking and host render poses/FOV. Confirm world-lock and image orientation visually; not a performance benchmark.'
echo 'Hold B/Y for one second to return to welcome.'
