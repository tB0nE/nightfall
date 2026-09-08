#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 <Android asset directory>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ASSET_DIR="$1"
ZIPDEPTH_384_MODEL="${NIGHTFALL_ZIPDEPTH_384_MODEL:-$PROJECT_ROOT/models/zipdepth-base-384-gpu.tflite}"

if [[ ! -f "$ZIPDEPTH_384_MODEL" ]]; then
  echo "Error: ZipDepth-384 model not found at $ZIPDEPTH_384_MODEL" >&2
  exit 1
fi

mkdir -p "$ASSET_DIR"
echo "Bundling ZipDepth-384 model: $ZIPDEPTH_384_MODEL"
cp "$ZIPDEPTH_384_MODEL" "$ASSET_DIR/zipdepth-base-384-gpu.tflite"

# Android intentionally ships only ZipDepth-384-GPU. The Java loader still
# soft-fails the models below so they can be re-enabled after platform policy
# is unlocked and performance is re-benchmarked. Uncomment only the required
# copies; see models/README.md for provenance and compatibility details.
# cp "$PROJECT_ROOT/models/midas-midas-v2-w8a8.tflite" "$ASSET_DIR/"
# cp "$PROJECT_ROOT/models/midas-v21-small-192-int8.tflite" "$ASSET_DIR/"
# cp "$PROJECT_ROOT/models/midas-v21-small-192-gpu.tflite" "$ASSET_DIR/"
# cp "$PROJECT_ROOT/models/midas-v21-small-256-gpu.tflite" "$ASSET_DIR/"
# cp "$PROJECT_ROOT/models/depth-anything-v2-small-252.tflite" "$ASSET_DIR/"
# cp "$PROJECT_ROOT/models/zipdepth-base-384-standard-w8a32.tflite" \
#   "$ASSET_DIR/zipdepth-base-384-cpu.tflite"
# cp "$PROJECT_ROOT/models/zipdepth-base-512x288-gpu.tflite" "$ASSET_DIR/"
# cp "$PROJECT_ROOT/models/zipdepth-base-672x384-gpu.tflite" "$ASSET_DIR/"
