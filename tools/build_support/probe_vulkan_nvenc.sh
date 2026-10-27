#!/usr/bin/env bash
# Explicit NVIDIA/Linux hardware diagnostic; never changes runtime registration.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
source "$TOOL_DIR/monado_xr_versions.sh"
REFERENCE="$ROOT/.build-cache/meteor-xr/WiVRn"
OUT="$ROOT/.build-cache/meteor-xr/nvenc-spike"
[[ "$(git -C "$REFERENCE" rev-parse HEAD)" == "$NIGHTFALL_WIVRN_REFERENCE_COMMIT" ]]
[[ -z "$(git -C "$REFERENCE" status --porcelain --untracked-files=no)" ]]
mkdir -p "$OUT"
c++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers \
    -I "$REFERENCE/external/ffnvcodec" "$ROOT/test/meteor_vulkan_nvenc_probe.cpp" \
    -lvulkan -ldl -o "$OUT/interop-probe"
timeout 30s "$OUT/interop-probe" "$OUT/stereo.h264" | tee "$OUT/encode.log"
ffmpeg -nostdin -hide_banner -loglevel error -y -i "$OUT/stereo.h264" \
    -frames:v 5 -pix_fmt rgb24 -f rawvideo "$OUT/decoded.rgb"
python3 "$ROOT/test/check_nvenc_stereo.py" "$OUT/decoded.rgb"
