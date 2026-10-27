#!/usr/bin/env bash
# Isolated runtime/IPC probe. Does not install/register a runtime or use a headset.
set -euo pipefail
TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TOOL_DIR/../.." && pwd)"
source "$TOOL_DIR/monado_xr_versions.sh"
MODE="${1:---check}"
case "$MODE" in --check|--build|--test) ;; *) echo 'Use --check, --build or --test' >&2; exit 2 ;; esac
CACHE="$ROOT/.build-cache/meteor-xr"
SOURCE="$CACHE/monado"
OUT="$CACHE/monado-linux-spike"
IMAGE="nightfall-monado-spike:ubuntu24.04"
if [[ "$MODE" == "--check" ]]; then
    command -v docker
    for item in "monado:$NIGHTFALL_MONADO_COMMIT" "WiVRn:$NIGHTFALL_WIVRN_REFERENCE_COMMIT"; do
        name="${item%%:*}"; expected="${item#*:}"
        actual="$(git -C "$CACHE/$name" rev-parse HEAD)"
        [[ "$actual" == "$expected" ]] || { echo "$name revision mismatch" >&2; exit 1; }
        echo "$name: $actual"
    done
    echo 'No runtime/driver registration or host configuration changed.'
    exit 0
fi
mkdir -p "$CACHE"
for item in "monado:$NIGHTFALL_MONADO_COMMIT:$NIGHTFALL_MONADO_REPOSITORY" "WiVRn:$NIGHTFALL_WIVRN_REFERENCE_COMMIT:$NIGHTFALL_WIVRN_REFERENCE_REPOSITORY"; do
    name="${item%%:*}"; rest="${item#*:}"; revision="${rest%%:*}"; repository="${rest#*:}"
    if [[ ! -d "$CACHE/$name" ]]; then
        git init "$CACHE/$name"
        git -C "$CACHE/$name" fetch --depth 1 "$repository" "$revision"
        git -C "$CACHE/$name" checkout --detach FETCH_HEAD
    fi
    [[ "$(git -C "$CACHE/$name" rev-parse HEAD)" == "$revision" ]] || { echo "$name revision mismatch" >&2; exit 1; }
    [[ -z "$(git -C "$CACHE/$name" status --porcelain --untracked-files=no)" ]] || { echo "$name source modified" >&2; exit 1; }
done
mkdir -p "$OUT"
if [[ "$MODE" == "--build" ]]; then
    docker build -t "$IMAGE" -f "$TOOL_DIR/Dockerfile.monado-spike" "$TOOL_DIR"
    docker run --rm --network none --user "$(id -u):$(id -g)" \
      -v "$SOURCE:/source:ro" -v "$OUT:/out:rw" -v "$ROOT/test:/tests:ro" "$IMAGE" \
      bash /tests/build_monado_spike.sh
else
    docker run --rm --network none --user "$(id -u):$(id -g)" \
      -v "$OUT:/out:rw" -v "$ROOT/test:/tests:ro" "$IMAGE" \
      bash /tests/run_monado_spike.sh
fi
