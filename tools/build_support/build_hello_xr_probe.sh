#!/usr/bin/env bash
# Official sample, pinned source remains clean; only an output copy is adapted.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
source "$TOOL_DIR/monado_xr_versions.sh"
SOURCE="$ROOT/.build-cache/meteor-xr/OpenXR-SDK-Source"
OUT="$ROOT/.build-cache/meteor-xr/hello-xr-spike"
if [[ ! -d "$SOURCE/.git" ]]; then
    git init "$SOURCE"
    git -C "$SOURCE" fetch --depth 1 https://github.com/KhronosGroup/OpenXR-SDK-Source.git "$NIGHTFALL_OPENXR_SAMPLE_COMMIT"
    git -C "$SOURCE" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$NIGHTFALL_OPENXR_SAMPLE_COMMIT" ]]
[[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ]]
mkdir -p "$OUT"
docker build -t nightfall-monado-spike:ubuntu24.04 -f "$TOOL_DIR/Dockerfile.monado-spike" "$TOOL_DIR"
docker run --rm --network none --user "$(id -u):$(id -g)" \
    -v "$SOURCE:/source:ro" -v "$OUT:/out:rw" -v "$ROOT/test:/tests:ro" \
    nightfall-monado-spike:ubuntu24.04 bash /tests/build_hello_xr_probe.sh
