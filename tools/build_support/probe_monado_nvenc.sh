#!/usr/bin/env bash
# Linux/NVIDIA diagnostic: native test processes, process-local runtime only.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
source "$TOOL_DIR/monado_xr_versions.sh"
REFERENCE="$ROOT/.build-cache/meteor-xr/WiVRn"
OUT="${NIGHTFALL_XR_PROBE_OUTPUT:-$ROOT/.build-cache/meteor-xr/monado-nvenc-spike}"
[[ "$(git -C "$REFERENCE" rev-parse HEAD)" == "$NIGHTFALL_WIVRN_REFERENCE_COMMIT" ]]
[[ -z "$(git -C "$REFERENCE" status --porcelain --untracked-files=no)" ]]
mkdir -p "$OUT"
PROBE_PYTHON="${NIGHTFALL_PROBE_PYTHON:-$ROOT/.build-cache/model-tester-venv/bin/python}"
[[ -x "$PROBE_PYTHON" ]] || PROBE_PYTHON=python3
"$PROBE_PYTHON" "$ROOT/test/xr_preflight_cache.py" "$ROOT" "$REFERENCE" "$OUT"
"$PROBE_PYTHON" "$ROOT/test/run_monado_nvenc_spike.py" "$ROOT" "$OUT"
