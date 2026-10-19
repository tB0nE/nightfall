#!/usr/bin/env bash
# Isolated copy of the existing pinned toolchain; never changes APK inputs.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
source "$TOOL_DIR/native_xr_versions.sh"
SOURCE="$ROOT/.build-cache/native-xr/godot"
DEST="$ROOT/.build-cache/meteor-xr/godot-engine-cleanup"
FIX="$ROOT/patches/godot-4.7-xr-engine-cleanup.patch"
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$NIGHTFALL_PINNED_GODOT_COMMIT" ]]
if [[ ! -e "$DEST" ]]; then
    mkdir -p "$DEST"
    # Do not silently duplicate the large engine build if reflinks are unavailable.
    cp -a --reflink=always "$SOURCE/." "$DEST/"
fi
[[ "$(git -C "$DEST" rev-parse HEAD)" == "$NIGHTFALL_PINNED_GODOT_COMMIT" ]]
if ! git -C "$DEST" apply --reverse --check --unidiff-zero "$FIX" >/dev/null 2>&1; then
    patch --forward --batch --fuzz=0 -d "$DEST" -p1 < "$FIX"
fi
PATH="/usr/bin:$PATH" scons -C "$DEST" platform=linuxbsd target=editor use_static_cpp=no -j"${NIGHTFALL_ENGINE_JOBS:-4}"
echo "Engine fixture executable: $DEST/bin/godot.linuxbsd.editor.x86_64"
