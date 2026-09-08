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
