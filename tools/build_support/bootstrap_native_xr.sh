#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=native_xr_versions.sh
source "$SCRIPT_DIR/native_xr_versions.sh"

CACHE_ROOT="${NIGHTFALL_NATIVE_XR_CACHE:-$PROJECT_ROOT/.build-cache/native-xr}"
GODOT_SOURCE="${NIGHTFALL_GODOT_SOURCE:-$CACHE_ROOT/godot}"
GODOT_CPP="${NIGHTFALL_GODOT_CPP:-$CACHE_ROOT/godot-cpp}"
RUNTIME_DIR="$CACHE_ROOT/templates/$NIGHTFALL_GODOT_TEMPLATE_VERSION"
PATCH_STAMP="$CACHE_ROOT/godot-patches.sha256"
API_STAMP="$CACHE_ROOT/godot-cpp-api.version"
JOBS="${NIGHTFALL_BUILD_JOBS:-$(nproc)}"
SOURCES_ONLY=0
ENGINE_PATCHES=(
  "$PROJECT_ROOT/patches/godot-4.7-ahb.patch"
  "$PROJECT_ROOT/patches/godot-4.7-projectionless.patch"
  "$PROJECT_ROOT/patches/godot-4.7-projectionless-lifecycle.patch"
  "$PROJECT_ROOT/patches/godot-4.7-compositor-filter.patch"
)

usage() {
  cat <<EOF
Usage: $0 [--sources-only]

Recreates Nightfall's patched native-XR toolchain from pinned upstream commits.
By default it builds the patched editor, OpenXR-aware godot-cpp bindings, and
both Android runtime libraries. Artifacts are cached under:
  $CACHE_ROOT

Options:
  --sources-only  Clone and patch the pinned sources without compiling them
  --help          Show this help

Environment overrides:
  NIGHTFALL_NATIVE_XR_CACHE, NIGHTFALL_GODOT_SOURCE, NIGHTFALL_GODOT_CPP,
  NIGHTFALL_BUILD_JOBS, ANDROID_HOME, ANDROID_NDK_ROOT
EOF
}

for arg in "$@"; do
  case "$arg" in
    --sources-only) SOURCES_ONLY=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

prepare_checkout() {
  local repository="$1"
  local commit="$2"
  local destination="$3"
  local label="$4"
  local fresh_clone=0

  if [[ ! -d "$destination/.git" ]]; then
    if [[ -e "$destination" ]]; then
      echo "Refusing to replace non-Git path: $destination" >&2
      exit 1
    fi
    echo "Cloning pinned $label source..."
    git clone --filter=blob:none --no-checkout "$repository" "$destination"
    fresh_clone=1
  fi

  if ! git -C "$destination" cat-file -e "$commit^{commit}" 2>/dev/null; then
    echo "Fetching pinned $label commit $commit..."
    git -C "$destination" fetch --depth=1 origin "$commit"
  fi

  if [[ "$fresh_clone" -eq 1 ]]; then
    git -C "$destination" checkout --detach "$commit"
    return
  fi

  local current_commit
  current_commit="$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$current_commit" && "$current_commit" != "$commit" ]]; then
    echo "$label checkout is at $current_commit, expected $commit: $destination" >&2
    echo "Move that checkout aside or set the corresponding NIGHTFALL_* path." >&2
    exit 1
  fi
  if [[ -z "$current_commit" ]]; then
    git -C "$destination" checkout --detach "$commit"
  fi
}

apply_engine_patch() {
  local patch_file="$1"
  if git -C "$GODOT_SOURCE" apply --check "$patch_file" 2>/dev/null; then
    echo "Applying $(basename "$patch_file")..."
    git -C "$GODOT_SOURCE" apply "$patch_file"
  elif git -C "$GODOT_SOURCE" apply --reverse --check "$patch_file" 2>/dev/null; then
    echo "Already applied: $(basename "$patch_file")"
  else
    echo "Patch does not apply cleanly to the pinned engine: $patch_file" >&2
    exit 1
  fi
}

require_command git
mkdir -p "$CACHE_ROOT"
prepare_checkout "$NIGHTFALL_PINNED_GODOT_REPOSITORY" "$NIGHTFALL_PINNED_GODOT_COMMIT" "$GODOT_SOURCE" "Godot"

EXPECTED_PATCH_STAMP="Godot $NIGHTFALL_PINNED_GODOT_COMMIT"
for patch_file in "${ENGINE_PATCHES[@]}"; do
  EXPECTED_PATCH_STAMP+=$'\n'"$(sha256sum "$patch_file" | cut -d' ' -f1)  $(basename "$patch_file")"
done

if [[ -f "$PATCH_STAMP" ]] && [[ "$(<"$PATCH_STAMP")" == "$EXPECTED_PATCH_STAMP" ]]; then
  echo "Pinned Godot patch set is already applied."
else
  for patch_file in "${ENGINE_PATCHES[@]}"; do
    apply_engine_patch "$patch_file"
  done
  printf '%s\n' "$EXPECTED_PATCH_STAMP" > "$PATCH_STAMP"
fi

prepare_checkout "$NIGHTFALL_PINNED_GODOT_CPP_REPOSITORY" "$NIGHTFALL_PINNED_GODOT_CPP_COMMIT" "$GODOT_CPP" "godot-cpp"

if [[ "$SOURCES_ONLY" -eq 1 ]]; then
  echo "Pinned sources are ready:"
  echo "  Godot:    $GODOT_SOURCE"
  echo "  godot-cpp: $GODOT_CPP"
  exit 0
fi

require_command scons
require_command cmake
require_command ninja

HOST_BUILD_PATH="$PATH"
if [[ -z "${CC:-}" && -z "${CXX:-}" ]] \
  && [[ "$(command -v g++ 2>/dev/null || true)" == "/usr/bin/g++" ]] \
  && [[ -x /usr/bin/ld ]] \
  && [[ "$(command -v ld 2>/dev/null || true)" != "/usr/bin/ld" ]]; then
  # Keep the host compiler and linker from different package managers from
  # being mixed (for example, system GCC with Linuxbrew binutils).
  HOST_BUILD_PATH="/usr/bin:$PATH"
fi

echo "Building patched Godot editor..."
PATH="$HOST_BUILD_PATH" scons -C "$GODOT_SOURCE" platform=linuxbsd target=editor \
  use_static_cpp=no -j"$JOBS"

GODOT_EDITOR=""
for candidate in "$GODOT_SOURCE"/bin/godot.linuxbsd.editor.*; do
  if [[ -x "$candidate" ]]; then
    GODOT_EDITOR="$candidate"
    break
  fi
done
if [[ -z "$GODOT_EDITOR" ]]; then
  echo "Patched Godot editor was not produced under $GODOT_SOURCE/bin" >&2
  exit 1
fi

EXPECTED_API_STAMP="Godot $NIGHTFALL_PINNED_GODOT_COMMIT / godot-cpp $NIGHTFALL_PINNED_GODOT_CPP_COMMIT"
if [[ -f "$API_STAMP" ]] \
  && [[ "$(<"$API_STAMP")" == "$EXPECTED_API_STAMP" ]] \
  && [[ -f "$GODOT_CPP/extension_api.json" ]] \
  && [[ -f "$GODOT_CPP/gdextension/gdextension_interface.json" ]]; then
  echo "Patched extension API is already generated."
else
  echo "Generating patched extension API..."
  (
    cd "$GODOT_CPP"
    "$GODOT_EDITOR" --headless --dump-extension-api \
      --dump-gdextension-interface-json --dump-gdextension-interface
    cp gdextension_interface.json gdextension/gdextension_interface.json
  )
  printf '%s\n' "$EXPECTED_API_STAMP" > "$API_STAMP"
fi
if [[ ! -f "$GODOT_CPP/extension_api.json" ]]; then
  echo "Godot did not produce $GODOT_CPP/extension_api.json" >&2
  exit 1
fi

ANDROID_HOME="${ANDROID_HOME:-/home/linuxbrew/.linuxbrew/share/android-commandlinetools}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-$ANDROID_HOME/ndk/$NIGHTFALL_ANDROID_NDK_VERSION}"
if [[ ! -f "$ANDROID_NDK_ROOT/build/cmake/android.toolchain.cmake" ]]; then
  echo "Android NDK $NIGHTFALL_ANDROID_NDK_VERSION was not found at $ANDROID_NDK_ROOT" >&2
  echo "Set ANDROID_HOME or ANDROID_NDK_ROOT to the matching SDK installation." >&2
  exit 1
fi
export ANDROID_HOME ANDROID_NDK_ROOT

for target in debug release; do
  echo "Building godot-cpp Android $target bindings..."
  scons -C "$GODOT_CPP" platform=android target="template_$target" arch=arm64 \
    android_api_level=24 ndk_version="$NIGHTFALL_ANDROID_NDK_VERSION" \
    custom_api_file="$GODOT_CPP/extension_api.json" -j"$JOBS"
done

mkdir -p "$RUNTIME_DIR"
echo "Building patched Android debug runtime..."
scons -C "$GODOT_SOURCE" platform=android target=template_debug arch=arm64 -j"$JOBS"
DEBUG_RUNTIME="$GODOT_SOURCE/platform/android/java/lib/libs/debug/arm64-v8a/libgodot_android.so"
if [[ ! -f "$DEBUG_RUNTIME" ]]; then
  DEBUG_RUNTIME="$GODOT_SOURCE/bin/libgodot.android.template_debug.arm64.so"
fi
if [[ ! -f "$DEBUG_RUNTIME" ]]; then
  echo "Godot debug runtime was not produced in a known output location." >&2
  exit 1
fi
cp "$DEBUG_RUNTIME" "$RUNTIME_DIR/android_debug_arm64.so"

echo "Building patched Android release runtime..."
scons -C "$GODOT_SOURCE" platform=android target=template_release arch=arm64 -j"$JOBS"
RELEASE_RUNTIME="$GODOT_SOURCE/platform/android/java/lib/libs/release/arm64-v8a/libgodot_android.so"
if [[ ! -f "$RELEASE_RUNTIME" ]]; then
  RELEASE_RUNTIME="$GODOT_SOURCE/bin/libgodot.android.template_release.arm64.so"
fi
if [[ ! -f "$RELEASE_RUNTIME" ]]; then
  echo "Godot release runtime was not produced in a known output location." >&2
  exit 1
fi
cp "$RELEASE_RUNTIME" "$RUNTIME_DIR/android_release_arm64.so"

echo "Native-XR toolchain ready:"
echo "  Godot source: $GODOT_SOURCE"
echo "  godot-cpp:    $GODOT_CPP"
echo "  runtimes:     $RUNTIME_DIR"
