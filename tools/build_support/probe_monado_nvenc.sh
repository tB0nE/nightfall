#!/usr/bin/env bash
# Linux/NVIDIA diagnostic: native test processes, process-local runtime only.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
source "$TOOL_DIR/monado_xr_versions.sh"
REFERENCE="$ROOT/.build-cache/meteor-xr/WiVRn"
OUT="$ROOT/.build-cache/meteor-xr/monado-nvenc-spike"
[[ "$(git -C "$REFERENCE" rev-parse HEAD)" == "$NIGHTFALL_WIVRN_REFERENCE_COMMIT" ]]
[[ -z "$(git -C "$REFERENCE" status --porcelain --untracked-files=no)" ]]
mkdir -p "$OUT"
cc -std=c11 -Wall -Wextra -Werror "$ROOT/test/monado_image_lease_test.c" -o "$OUT/image-lease-tests"
"$OUT/image-lease-tests"
cc -std=c11 -Wall -Wextra -Werror -pthread "$ROOT/test/meteor_latest_job_queue_test.c" -o "$OUT/latest-job-tests"
timeout 10s "$OUT/latest-job-tests"
cc -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror -pthread \
    "$ROOT/test/monado_async_transport_test.c" -o "$OUT/async-transport-tests"
timeout 10s "$OUT/async-transport-tests"
c++ -std=c++17 -O2 -fPIC -shared -pthread -Wall -Wextra -Werror \
    -I "$ROOT/extensions/nightfall-xr/include" \
    "$ROOT/test/meteor_tracking_client_bridge.cpp" -o "$OUT/libmeteor-tracking-probe.so"
c++ -std=c++17 -O2 -fPIC -shared -pthread -DMETEOR_MONADO_BRIDGE \
    -Wall -Wextra -Werror -Wno-missing-field-initializers \
    -I "$REFERENCE/external/ffnvcodec" "$ROOT/test/meteor_vulkan_nvenc_probe.cpp" \
    -lvulkan -ldl -o "$OUT/libmeteor-nvenc-probe.so"
PROBE_PYTHON="${NIGHTFALL_PROBE_PYTHON:-$ROOT/.build-cache/model-tester-venv/bin/python}"
[[ -x "$PROBE_PYTHON" ]] || PROBE_PYTHON=python3
"$PROBE_PYTHON" "$ROOT/test/run_monado_nvenc_spike.py" "$ROOT" "$OUT"
