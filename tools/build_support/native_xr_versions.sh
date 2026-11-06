#!/usr/bin/env bash

# Immutable upstream inputs for Nightfall's patched Android Godot runtime and
# OpenXR-aware godot-cpp bindings. Keep these values in source control so a
# fresh checkout does not depend on whatever happens to be at a branch tip.
NIGHTFALL_PINNED_GODOT_REPOSITORY="https://github.com/godotengine/godot.git"
NIGHTFALL_PINNED_GODOT_COMMIT="5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88"
NIGHTFALL_PINNED_GODOT_CPP_REPOSITORY="https://github.com/godotengine/godot-cpp.git"
NIGHTFALL_PINNED_GODOT_CPP_COMMIT="05057de73de4b99f114d36c40d84ca46926c0e25"
NIGHTFALL_GODOT_TEMPLATE_VERSION="4.7.stable"
NIGHTFALL_ANDROID_NDK_VERSION="29.0.14206865"
NIGHTFALL_LITERT_GPU_AAR_SHA256="f8b5ac0eb523b307d7d7cb4e024941f0cf64fd9a12f72726ed2d6d7e81928700"

NIGHTFALL_ENGINE_PATCH_NAMES=(
  godot-4.7-ahb.patch
  godot-4.7-projectionless.patch
  godot-4.7-projectionless-lifecycle.patch
  godot-4.7-compositor-filter.patch
  godot-4.7-gles3-render-target-override.patch
)

# A source-tree stamp alone cannot prove that a cached binary was rebuilt.
nightfall_runtime_build_stamp() {
  local root="$1" runtime="$2" patch_name
  printf 'Godot %s\n' "$NIGHTFALL_PINNED_GODOT_COMMIT"
  for patch_name in "${NIGHTFALL_ENGINE_PATCH_NAMES[@]}"; do
    printf '%s  %s\n' "$(sha256sum "$root/patches/$patch_name" | cut -d' ' -f1)" "$patch_name"
  done
  printf 'Runtime %s\n' "$(sha256sum "$runtime" | cut -d' ' -f1)"
}

nightfall_validate_runtime_build() {
  local root="$1" runtime="$2" expected
  [[ -f "$runtime" && -f "$runtime.build-stamp" ]] || return 1
  expected="$(nightfall_runtime_build_stamp "$root" "$runtime")" || return 1
  [[ "$(cat "$runtime.build-stamp")" == "$expected" ]]
}
