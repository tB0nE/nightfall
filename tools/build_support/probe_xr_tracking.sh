#!/usr/bin/env bash
# Host receiver for the DEV headset's separate USB tracking endpoint.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
ADB="${NIGHTFALL_ADB:-adb}"
OUT="$ROOT/.build-cache/meteor-xr/tracking-spike"
mkdir -p "$OUT"
c++ -std=c++17 -O2 -Wall -Wextra -Werror \
    -I"$ROOT/extensions/nightfall-xr/include" \
    "$ROOT/test/meteor_tracking_host_probe.cpp" -o "$OUT/host-probe"
PORT="$("$ADB" forward tcp:0 tcp:49091)"
[[ "$PORT" =~ ^[0-9]+$ ]]
trap '"$ADB" forward --remove "tcp:$PORT" >/dev/null 2>&1 || true' EXIT
"$OUT/host-probe" "$PORT" > "$OUT/head-poses.jsonl"
echo "Pose evidence: $OUT/head-poses.jsonl"
