#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${1:?Usage: build.sh VERSION}"
CACHE="$ROOT/.build-cache/steam-frame-preview"
mkdir -p "$CACHE"
docker build -t nightfall-linux-builder -f "$ROOT/Dockerfile.linux-build" "$ROOT"
docker build -t nightfall-steam-frame-cross -f "$ROOT/tools/steam_frame/Dockerfile.cross" "$ROOT/tools/steam_frame"
docker run --rm --name nightfall-frame-preview-build -e VCPKG_MAX_CONCURRENCY=8 \
  -v "$ROOT/addons/nightfall-stream:/source:ro" -v "$CACHE:/work" \
  -v "$ROOT/tools/steam_frame/build-native.sh:/build-native.sh:ro" \
  nightfall-steam-frame-cross bash /build-native.sh
bash "$ROOT/tools/steam_frame/package.sh" "$VERSION"
