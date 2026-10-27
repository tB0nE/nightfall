#!/usr/bin/env bash
# Arms a USB-only fixture, then waits for the user to press the DEV button.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
ADB="${NIGHTFALL_ADB:-adb}"
OUT="$ROOT/.build-cache/meteor-xr/headset-projection-spike"
mkdir -p "$OUT"
PORT="$("$ADB" forward tcp:0 tcp:49090)"
[[ "$PORT" =~ ^[0-9]+$ ]]
LOG_PID=""
cleanup() {
    if [[ -n "$LOG_PID" ]]; then kill "$LOG_PID" 2>/dev/null || true; wait "$LOG_PID" 2>/dev/null || true; fi
    "$ADB" forward --remove "tcp:$PORT" >/dev/null 2>&1 || true
}
trap cleanup EXIT
"$ADB" logcat -T 1 -v brief -s NightfallPCVR:I > "$OUT/device.log" 2>&1 &
LOG_PID=$!
echo 'Fixture armed. From clean welcome, tap DEV: Meteor decoded stereo. Hold B/Y for 1s to exit.'
READY=0
for attempt in {1..1200}; do
    if rg -q 'Meteor projection receiver requested' "$OUT/device.log" && rg -q 'Listening on loopback :49090' "$OUT/device.log"; then READY=1; break; fi
    kill -0 "$LOG_PID" || { tail -20 "$OUT/device.log"; exit 1; }
    sleep 0.05
done
[[ "$READY" == 1 ]] || { echo 'No projection test started within 60 seconds' >&2; exit 1; }
# Prove poses and explicit clock mapping before any video is sent. A separate
# forward/channel avoids ACK interleaving with the existing encoded-frame probe.
bash "$TOOL_DIR/probe_xr_tracking.sh"
NIGHTFALL_XR_DEVICE_PORT="$PORT" NIGHTFALL_XR_PROBE_FRAMES="${NIGHTFALL_XR_PROBE_FRAMES:-120}" \
    bash "$TOOL_DIR/probe_monado_nvenc.sh"
rg -q 'METEOR DECODED.*first frame: ONE projection layer' "$OUT/device.log" || {
    tail -30 "$OUT/device.log"; echo 'No decoded XR projection evidence' >&2; exit 1;
}
echo 'Decoded projection reported. Check eye colors/orientation visually; local poses only, not tracked PCVR.'
echo 'Hold B/Y for 1 second to return to welcome (45-second automatic exit).'
