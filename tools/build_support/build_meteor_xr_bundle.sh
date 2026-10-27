#!/usr/bin/env bash
# Baseline-compatible managed XR bundle. No host packages, drivers or services changed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/tools/build_support/monado_xr_versions.sh"
SOURCE="$ROOT/.build-cache/meteor-xr/monado"
REFERENCE="$ROOT/.build-cache/meteor-xr/WiVRn"
OUT="${1:-$ROOT/.build-cache/meteor-xr/portable-package}"
XRIZER="${NIGHTFALL_XRIZER_PACKAGE:-$ROOT/.build-cache/meteor-xr/xrizer-package/runtime}"
if [[ ! -s "$XRIZER/DEPENDENCY_NOTICES.txt" || ! -f "$XRIZER/UPSTREAM_REVISION" ]]; then
    bash "$ROOT/tools/build_support/build_meteor_xrizer.sh" "$(dirname "$XRIZER")"
fi
[[ "$(cat "$XRIZER/UPSTREAM_REVISION")" == "$NIGHTFALL_XRIZER_COMMIT" ]]
[[ ! -e "$OUT/bundle" ]] || { echo 'Choose a new output directory; bundle already exists.' >&2; exit 1; }
for pair in "$SOURCE:$NIGHTFALL_MONADO_COMMIT" "$REFERENCE:$NIGHTFALL_WIVRN_REFERENCE_COMMIT"; do
    tree="${pair%:*}"; revision="${pair##*:}"
    [[ "$(git -C "$tree" rev-parse HEAD)" == "$revision" ]]
    [[ -z "$(git -C "$tree" status --porcelain --untracked-files=no)" ]]
done
ENGINE="${NIGHTFALL_CONTAINER_ENGINE:-docker}"
IMAGE=nightfall-meteor-xr-build:ubuntu22.04
mkdir -p "$OUT/compiled" "$OUT/ffmpeg-build"
# Pin the same LGPL FFmpeg source as the AppImage, before the offline build.
ARCHIVE="$OUT/ffmpeg-build/ffmpeg-8.0.1.tar.xz"
if [[ ! -f "$ARCHIVE" ]]; then
    EXISTING="$ROOT/meteor/target/appimage/cargo-target/ffmpeg-build/ffmpeg-8.0.1.tar.xz"
    if [[ -f "$EXISTING" ]]; then cp "$EXISTING" "$ARCHIVE";
    else curl -fL --retry 3 https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz -o "$ARCHIVE"; fi
fi
OUT="$(cd "$OUT" && pwd)"
"$ENGINE" build --build-arg UBUNTU_VERSION=22.04 -t "$IMAGE" \
    -f "$ROOT/tools/build_support/Dockerfile.monado-spike" "$ROOT/tools/build_support"
"$ENGINE" run --rm --network none --user "$(id -u):$(id -g)" \
    -v "$ROOT:/repo:ro" -v "$SOURCE:/source:ro" -v "$REFERENCE:/reference:ro" \
    -v "$ROOT/test:/tests:ro" -v "$OUT:/output:rw" -v "$OUT/compiled:/out:rw" \
    -v "$XRIZER:/xrizer:ro" -e PYTHONDONTWRITEBYTECODE=1 \
    "$IMAGE" bash -euo pipefail -c '
NIGHTFALL_XR_PACKAGE_ONLY=1 bash /tests/build_monado_spike.sh
bash /repo/meteor/tools/build_ffmpeg_runtime.sh /output/ffmpeg-runtime /output/ffmpeg-build
c++ -std=c++17 -O2 -fPIC -shared -pthread -DMETEOR_MONADO_BRIDGE \
    -Wall -Wextra -Werror -Wno-missing-field-initializers \
    /tests/meteor_vulkan_vaapi_probe.cpp -I/repo/meteor/third_party/ffmpeg/include -I/out \
    $(pkg-config --cflags --libs libva libva-drm libdrm vulkan) -ldl \
    -o /output/libmeteor-vaapi-probe.so
mkdir -p /output/root/.build-cache/meteor-xr
ln -sfn /out /output/root/.build-cache/meteor-xr/monado-linux-spike
for directory in test tools extensions; do ln -sfn "/repo/$directory" "/output/root/$directory"; done
ln -sfn /repo/LICENSE /output/root/LICENSE
ln -sfn /reference /output/root/.build-cache/meteor-xr/WiVRn
mkdir -p /output/root/.build-cache/meteor-xr/build-notices
cp /usr/share/doc/libeigen3-dev/copyright /output/root/.build-cache/meteor-xr/build-notices/Eigen3-copyright.txt
cp /usr/share/doc/libcjson1/copyright /output/root/.build-cache/meteor-xr/build-notices/cJSON-package-copyright.txt
cp /output/ffmpeg-runtime/FFmpeg-COPYING.LGPLv2.1 /output/root/.build-cache/meteor-xr/build-notices/FFmpeg-COPYING.LGPLv2.1.txt
cp /output/ffmpeg-runtime/dav1d-copyright /output/root/.build-cache/meteor-xr/build-notices/dav1d-copyright.txt
python3 /repo/test/xr_preflight_cache.py /output/root /reference /output/helper-session
python3 - <<PY
import sys
from pathlib import Path
sys.path.insert(0,"/repo/tools/build_support")
import stage_meteor_xr_runtime as staging
import json
helper_root=Path("/output/root/.build-cache/meteor-xr/helper-cache")
sys.path.insert(0,"/repo/test")
from xr_preflight_cache import fingerprint
validated=[helper_root/fingerprint(Path("/output/root"),Path("/reference"))]
if not (validated[0]/"validated.json").is_file(): raise RuntimeError("Missing source-matched baseline helper build")
private=Path("/output/ffmpeg-runtime/lib")
libraries=[Path("/usr/lib/x86_64-linux-gnu/libcjson.so.1"), *[private/name for name in ("libavcodec.so.62","libavutil.so.60","libswscale.so.9")], *private.glob("libdav1d.so.*")]
staging.stage(Path("/output/root"),Path("/output/bundle"),validated[0],
              libraries, Path("/xrizer"), vaapi=Path("/output/libmeteor-vaapi-probe.so"))
PY
# Bundle libcjson next to the bridges; host Vulkan/udev/graphics drivers remain external.
for binary in /output/bundle/.build-cache/meteor-xr/monado-linux-spike/capture-build/src/xrt/targets/service/monado-service /output/bundle/.build-cache/meteor-xr/monado-linux-spike/capture-build/src/xrt/targets/openxr/libopenxr_monado.so; do
    # The launcher supplies the private library directory to owned processes.
    readelf -d "$binary" >/dev/null
done
python3 /repo/tools/audit_meteor_xr_runtime.py /output/bundle --max-glibc 2.35 --output /output/runtime-audit.json
'
echo "Verified baseline XR bundle: $OUT/bundle"
