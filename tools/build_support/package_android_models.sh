#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 <Android asset directory>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ASSET_DIR="$1"

# Android's production tier set. Historical/profiling exports stay under
# models/ and are documented in models/README.md, but are deliberately not
# carried in every APK.
# The two EdgePad classes run the widescreen family (2026-10-04), copied
# from nightfall-temporal-zipdepth's selected exports; see models/README.md.
# The square 384/256/224 exports they replaced stay in models/ as the rollback.
ZIPDEPTH_STANDARD_MODEL="${NIGHTFALL_ZIPDEPTH_STANDARD_MODEL:-$PROJECT_ROOT/models/zipdepth-wide-512x288-edgepad-gpu.tflite}"
ZIPDEPTH_EDGEPAD_320_MODEL="${NIGHTFALL_ZIPDEPTH_EDGEPAD_320_MODEL:-$PROJECT_ROOT/models/zipdepth-wide-320x180-t320x192-edgepad-gpu.tflite}"
# CPU twin of EdgePad-256 (tools/quantize_zipdepth_cpu.py --size 256), run through
# XNNPACK with no GPU delegate at all - selected via the "Backend" control's CPU
# option so AI 3D can run while leaving the GPU entirely to the stream/passthrough.
ZIPDEPTH_EDGEPAD_256_CPU_MODEL="${NIGHTFALL_ZIPDEPTH_EDGEPAD_256_CPU_MODEL:-$PROJECT_ROOT/models/zipdepth-base-256-cpu.tflite}"
# CPU twin of EdgePad-384 (tools/quantize_zipdepth_cpu.py, default --size 384).
ZIPDEPTH_EDGEPAD_384_CPU_MODEL="${NIGHTFALL_ZIPDEPTH_EDGEPAD_384_CPU_MODEL:-$PROJECT_ROOT/models/zipdepth-base-384-cpu.tflite}"

declare -A REQUIRED_MODELS=(
  ["EdgePad-512"]="$ZIPDEPTH_STANDARD_MODEL"
  ["EdgePad-320"]="$ZIPDEPTH_EDGEPAD_320_MODEL"
  ["EdgePad-256-CPU"]="$ZIPDEPTH_EDGEPAD_256_CPU_MODEL"
  ["EdgePad-384-CPU"]="$ZIPDEPTH_EDGEPAD_384_CPU_MODEL"
)
for label in "${!REQUIRED_MODELS[@]}"; do
  model_path="${REQUIRED_MODELS[$label]}"
  if [[ ! -f "$model_path" ]]; then
    echo "Error: $label model not found at $model_path" >&2
    exit 1
  fi
done

mkdir -p "$ASSET_DIR"
# Remove assets staged by an earlier comparison build. The model exports stay
# under models/ for future experiments; only the production APK is reduced.
rm -f \
  "$ASSET_DIR/zipdepth-base-384-direct-half-gpu.tflite" \
  "$ASSET_DIR/zipdepth-base-256-gpu.tflite" \
  "$ASSET_DIR/zipdepth-base-256-direct-half-gpu.tflite" \
  "$ASSET_DIR/zipdepth-base-384-standard-packed-conv4-reduceconv-edgepad-gpu.tflite" \
  "$ASSET_DIR/zipdepth-base-256-standard-packed-conv4-reduceconv-edgepad-gpu.tflite" \
  "$ASSET_DIR/zipdepth-base-224-standard-packed-conv4-reduceconv-edgepad-gpu.tflite" \
  "$ASSET_DIR/zipdepth-wide-352x198-t352x224-edgepad-gpu.tflite"
echo "Bundling EdgePad-512 model: $ZIPDEPTH_STANDARD_MODEL"
cp "$ZIPDEPTH_STANDARD_MODEL" \
  "$ASSET_DIR/zipdepth-wide-512x288-edgepad-gpu.tflite"
echo "Bundling EdgePad-320 model: $ZIPDEPTH_EDGEPAD_320_MODEL"
cp "$ZIPDEPTH_EDGEPAD_320_MODEL" \
  "$ASSET_DIR/zipdepth-wide-320x180-t320x192-edgepad-gpu.tflite"
echo "Bundling EdgePad-256-CPU model: $ZIPDEPTH_EDGEPAD_256_CPU_MODEL"
cp "$ZIPDEPTH_EDGEPAD_256_CPU_MODEL" \
  "$ASSET_DIR/zipdepth-base-256-cpu.tflite"
echo "Bundling EdgePad-384-CPU model: $ZIPDEPTH_EDGEPAD_384_CPU_MODEL"
cp "$ZIPDEPTH_EDGEPAD_384_CPU_MODEL" \
  "$ASSET_DIR/zipdepth-base-384-cpu.tflite"

# Opt-in cumulative profiling assets. Normal release APKs never include these;
# they are consumed only when GodotApp is launched through ADB with
# --es nightfall_depth_profile staged.
if [[ "${NIGHTFALL_INCLUDE_DEPTH_PROFILE_MODELS:-0}" == "1" ]]; then
  PROFILE_MODELS=(
    "zipdepth-base-384-profile-f1-gpu.tflite"
    "zipdepth-base-384-profile-f-half-gpu.tflite"
    "zipdepth-base-384-profile-mask-gpu.tflite"
    "zipdepth-base-384-profile-softmax-gpu.tflite"
    "zipdepth-base-384-profile-weighted-gpu.tflite"
  )
  for profile_model in "${PROFILE_MODELS[@]}"; do
    profile_path="$PROJECT_ROOT/models/$profile_model"
    if [[ ! -f "$profile_path" ]]; then
      echo "Error: ZipDepth profiling model not found at $profile_path" >&2
      exit 1
    fi
    echo "Bundling ZipDepth profiling model: $profile_path"
    cp "$profile_path" "$ASSET_DIR/$profile_model"
  done
fi

# Re-enable archived models only for a focused comparison build. Their files,
# conversion recipes, quality results, and Java indices are retained; see
# models/README.md and docs/guides/zipdepth-quest-tiers.md.
