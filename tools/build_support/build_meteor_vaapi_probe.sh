#!/usr/bin/env bash
# Standalone diagnostic only. No running Meteor/runtime/configuration modified.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/.build-cache/meteor-xr/amd-vaapi"
ENGINE="${NIGHTFALL_CONTAINER_ENGINE:-docker}"
mkdir -p "$OUT"
"$ENGINE" build -t nightfall-meteor-vaapi-probe:ubuntu22.04 \
    -f "$ROOT/tools/build_support/Dockerfile.meteor-vaapi-probe" "$ROOT/tools/build_support"
"$ENGINE" run --rm --network none --user "$(id -u):$(id -g)" \
    -v "$ROOT:/repo:ro" -v "$OUT:/output:rw" \
    nightfall-meteor-vaapi-probe:ubuntu22.04 bash -euo pipefail -c '
mkdir -p /output/validation
cp /usr/lib/x86_64-linux-gnu/libVkLayer_khronos_validation.so /usr/lib/x86_64-linux-gnu/libVkLayer_utils.so /output/validation/
cp /usr/share/vulkan/explicit_layer.d/VkLayer_khronos_validation.json /output/validation/
c++ -std=c++17 -O2 -Wall -Wextra -Werror /repo/test/meteor_vaapi_features.cpp \
    $(pkg-config --cflags --libs libva libva-drm) -o /output/meteor-vaapi-features
glslangValidator -V /repo/test/meteor_vaapi_pattern.comp -o /output/pattern.spv
c++ -std=c++17 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers \
    /repo/test/meteor_vulkan_vaapi_probe.cpp -I/repo/meteor/third_party/ffmpeg/include \
    $(pkg-config --cflags --libs libva libva-drm libdrm vulkan) -ldl \
    -o /output/meteor-vulkan-vaapi-probe
c++ -std=c++17 -O2 -fPIC -shared -pthread -DMETEOR_MONADO_BRIDGE \
    -Wall -Wextra -Werror -Wno-missing-field-initializers \
    /repo/test/meteor_vulkan_vaapi_probe.cpp -I/repo/meteor/third_party/ffmpeg/include \
    -I/repo/.build-cache/meteor-xr/monado-linux-spike \
    $(pkg-config --cflags --libs libva libva-drm libdrm vulkan) -ldl \
    -o /output/libmeteor-vaapi-probe.so
python3 - <<PY
import hashlib,json
from pathlib import Path
layer=Path("/output/validation/VkLayer_khronos_validation.json")
value=json.loads(layer.read_text());value["layer"]["library_path"]="./libVkLayer_khronos_validation.so"
layer.write_text(json.dumps(value,indent=2)+"\n")
names=["test/meteor_vaapi_features.cpp","test/meteor_vulkan_vaapi_probe.cpp","test/meteor_vaapi_pattern.comp",
       "tools/build_support/build_meteor_vaapi_probe.sh","tools/build_support/Dockerfile.meteor-vaapi-probe",
       "test/meteor_encoder_channel.h","test/meteor_stereo_compositor.h",
       "test/monado_nvenc_bridge.h","test/meteor_quad_compositor.h","test/meteor_quad_math.h",
       "test/meteor_eye_format.h","test/meteor_eye_rect.h","test/meteor_encoder_bitrate.h",
       "test/meteor_live_bitrate.h","test/meteor_live_foveation.h",
       "test/meteor_quad.vert","test/meteor_quad.frag",
       ".build-cache/meteor-xr/monado-linux-spike/meteor_quad.vert.h",
       ".build-cache/meteor-xr/monado-linux-spike/meteor_quad.frag.h"]
data={"sources":{name:hashlib.sha256((Path("/repo")/name).read_bytes()).hexdigest() for name in names}}
data["binary_sha256"]=hashlib.sha256(Path("/output/meteor-vulkan-vaapi-probe").read_bytes()).hexdigest()
data["bridge_sha256"]=hashlib.sha256(Path("/output/libmeteor-vaapi-probe.so").read_bytes()).hexdigest()
data["shader_sha256"]=hashlib.sha256(Path("/output/pattern.spv").read_bytes()).hexdigest()
Path("/output/validated-sources.json").write_text(json.dumps(data,indent=2)+"\n")
PY
'
