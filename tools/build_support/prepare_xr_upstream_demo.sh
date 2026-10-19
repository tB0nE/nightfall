#!/usr/bin/env bash
# Download only the pinned official demo into the ignored diagnostic cache.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
DEST="$ROOT/.build-cache/meteor-xr/godot-demo-projects"
PIN=b761b4cd5718a7118f2c95eb55f181d0a5f004f1
if [[ ! -e "$DEST" ]]; then
    git clone --filter=blob:none --no-checkout https://github.com/godotengine/godot-demo-projects.git "$DEST"
fi
[[ -z "$(git -C "$DEST" status --porcelain)" ]] || {
    echo 'Demo checkout has changes; preserve/review them before preparing.' >&2
    exit 1
}
git -C "$DEST" sparse-checkout set xr/openxr_origin_centric_movement
git -C "$DEST" checkout --detach "$PIN"
echo "Pinned upstream XR demo ready: $DEST"
