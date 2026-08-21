#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="nightfall-linux-builder"
SOURCE_DIR="$SCRIPT_DIR/addons/nightfall-stream"
OUTPUT_DIR="$SCRIPT_DIR/addons/nightfall-stream/bin/linux"
# Native AI-3D depth on Linux (2026-08-20) vendors TFLite via CMake
# FetchContent (see CMakeLists.txt) - a full clone of the tensorflow repo is
# ~1GB+ and slow to fetch/build repeatedly. Bind-mounted directly AT
# build/linux-release (not just FETCHCONTENT_BASE_DIR pointed elsewhere) so
# the whole tree - including third-party deps TFLite fetches ITSELF via its
# own "OverridableFetchContent" module (farmhash, gemmlowp, etc.) - persists
# consistently across runs. A partial-cache attempt (only FETCHCONTENT_BASE_DIR
# persisted, "rm -rf build/linux-release" every run) broke farmhash's
# populate step: its subbuild driver files remembered a prior successful
# fetch and tried a `git log`/update check against a checkout that had just
# been wiped, since OverridableFetchContent checks sources out relative to
# the build dir regardless of FETCHCONTENT_BASE_DIR. No `rm -rf` here
# anymore - CMake/Ninja handle incremental reconfigure/rebuild fine, and this
# also means our OWN code recompiles incrementally instead of from scratch
# every time, not just TFLite's fetch step.
#
# NOTE: the container runs as root, so this directory ends up root-owned on
# the host - `rm -rf` needs sudo, or clean it via a throwaway container, e.g.
# `docker run --rm -v "$PWD/.linux-build-cache:/c" alpine rm -rf /c/*`.
BUILD_CACHE_DIR="$SCRIPT_DIR/.linux-build-cache"
mkdir -p "$BUILD_CACHE_DIR"

docker build -t "$IMAGE_NAME" -f "$SCRIPT_DIR/Dockerfile.linux-build" "$SCRIPT_DIR"

docker run --rm \
    -v "$SOURCE_DIR:/build/source:ro" \
    -v "$OUTPUT_DIR:/build/output" \
    -v "$BUILD_CACHE_DIR:/build/work/build/linux-release" \
    "$IMAGE_NAME" \
    bash -c '
set -e
mkdir -p /build/work
# Exclude "build/" from the copy - a stale local build/ dir on the host
# source tree would otherwise land on top of (and corrupt) the persistent
# build/linux-release cache mounted separately above. tar --exclude (not cp)
# so this works whether or not the source happens to have one.
(cd /build/source && tar --exclude="./build" -cf - .) | (cd /build/work && tar -xf -)
cd /build/work

cmake --preset linux -DCMAKE_BUILD_TYPE=Release -B build/linux-release
cmake --build build/linux-release

cp build/linux-release/bin/linux/libnightfall-stream.linux.template_release.x86_64.so /build/output/
echo "Built: $(ls -lh /build/output/libnightfall-stream.linux.template_release.x86_64.so)"
'
