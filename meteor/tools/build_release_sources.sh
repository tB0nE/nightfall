#!/usr/bin/env bash
# Source companion to the Linux/XR AppImage. No user configuration is copied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="${NIGHTFALL_CONTAINER_ENGINE:-docker}"
OUT="$ROOT/.build-cache/meteor-release-packaging/sources"
DESTINATION="${1:?Pass a new output .tar.gz path}"
mkdir -p "$OUT"
"$ENGINE" run --rm --user "$(id -u):$(id -g)" \
    -v "$ROOT/meteor:/src:ro" -v "$OUT:/output:rw" \
    -v "$ROOT/meteor/target/appimage/cargo-registry:/opt/cargo/registry" \
    nightfall-meteor-appimage bash -euo pipefail -c '
cd /src
cargo vendor --locked /output/meteor > /output/meteor-cargo-config.toml
mkdir -p /output/build-notices
cp /usr/share/doc/libgomp1/copyright /output/build-notices/libgomp-copyright.txt
cp /usr/share/common-licenses/GPL-3 /output/build-notices/GPL-3.txt
dpkg-query -W libgomp1 libdav1d-dev > /output/build-notices/baseline-packages.txt
'
"$ENGINE" run --rm --user "$(id -u):$(id -g)" \
    -v "$ROOT/.build-cache/meteor-xr/xrizer:/src:ro" -v "$OUT:/output:rw" \
    -v "$ROOT/.build-cache/meteor-xr/xrizer-package/cargo-registry:/opt/cargo/registry" \
    nightfall-meteor-xrizer-build:ubuntu22.04 bash -euo pipefail -c '
cd /src
cargo vendor --locked /output/xrizer > /output/xrizer-cargo-config.toml
'
"$ENGINE" run --rm --network none --user "$(id -u):$(id -g)" \
    -v "$OUT:/output:rw" nightfall-meteor-xr-build:ubuntu22.04 bash -euo pipefail -c '
cp -a /usr/include/eigen3 /output/eigen
'
/usr/bin/python3 "$ROOT/meteor/tools/release_metadata.py" --archive "$DESTINATION" --vendor-root "$OUT"
sha256sum "$DESTINATION"
