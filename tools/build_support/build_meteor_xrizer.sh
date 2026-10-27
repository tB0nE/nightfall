#!/usr/bin/env bash
# Build our own OpenVR compatibility runtime; never copy a WiVRN installation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tools/build_support/monado_xr_versions.sh"
SOURCE="$ROOT/.build-cache/meteor-xr/xrizer"
OUT="${1:-$ROOT/.build-cache/meteor-xr/xrizer-package}"
ENGINE="${NIGHTFALL_CONTAINER_ENGINE:-docker}"
if [[ ! -d "$SOURCE/.git" ]]; then
    git init "$SOURCE"
    git -C "$SOURCE" fetch --depth 1 "$NIGHTFALL_XRIZER_REPOSITORY" "$NIGHTFALL_XRIZER_COMMIT"
    git -C "$SOURCE" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$NIGHTFALL_XRIZER_COMMIT" ]]
[[ -z "$(git -C "$SOURCE" status --porcelain --untracked-files=no)" ]]
mkdir -p "$OUT/cargo-registry" "$OUT/target"
OUT="$(cd "$OUT" && pwd)"
"$ENGINE" build -t nightfall-meteor-xrizer-build:ubuntu22.04 \
    -f "$ROOT/tools/build_support/Dockerfile.meteor-xrizer" "$ROOT/tools/build_support"
"$ENGINE" run --rm --user "$(id -u):$(id -g)" --security-opt label=disable \
    -v "$SOURCE:/src:ro" -v "$ROOT:/repo:ro" -v "$OUT:/output:rw" \
    -v "$OUT/cargo-registry:/opt/cargo/registry" -e CARGO_TARGET_DIR=/output/target \
    -e XRIZER_VERSION="0.6.0-nightfall-$NIGHTFALL_XRIZER_COMMIT" \
    -e XRIZER_REVISION="$NIGHTFALL_XRIZER_COMMIT" \
    nightfall-meteor-xrizer-build:ubuntu22.04 bash -euo pipefail -c '
cd /src
cargo xbuild --release --locked --no-default-features --features monado,static-openxr
mkdir -p /output/runtime/bin/linux64
cp -L /output/target/release/bin/linux64/vrclient.so /output/runtime/bin/linux64/vrclient.so
cp /output/target/release/bin/version.txt /output/runtime/bin/version.txt
cp /src/LICENSE /output/runtime/LICENSE
cp /src/Cargo.lock /output/runtime/Cargo.lock
# The three upstream workspace crates omit license metadata and rely on the
# repository GPL notice. Make that existing notice discoverable to cargo-about
# in a disposable metadata copy; the actual build uses the untouched checkout.
rm -rf /output/notice-source
mkdir -p /output/notice-source
cp -a /src/. /output/notice-source/
for crate in macros openvr shaders; do
    cp /src/LICENSE "/output/notice-source/$crate/LICENSE"
done
cd /output/notice-source
cargo about generate --no-default-features --features monado,static-openxr --fail \
    -c /repo/tools/build_support/xrizer-about.toml /repo/meteor/tools/appimage/about.hbs \
    > /output/runtime/DEPENDENCY_NOTICES.txt
printf "%s\n" "$XRIZER_REVISION" > /output/runtime/UPSTREAM_REVISION
printf "%s\n" "https://github.com/Supreeeme/xrizer/tree/$XRIZER_REVISION" > /output/runtime/SOURCE_URL
'
echo "Nightfall-owned xrizer runtime: $OUT/runtime"
