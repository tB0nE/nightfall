#!/usr/bin/env bash
set -euo pipefail
# Run only inside the isolated build image; no host package installs.
# Keep the pinned input clean; apply our diagnostic hook only to an output copy.
mkdir -p /out/capture-source
cp -a --remove-destination /source/. /out/capture-source/
patch --batch -d /out/capture-source -p1 < /tests/monado_capture_hook.patch
patch --batch --fuzz=0 -d /out/capture-source -p1 < /tests/monado_controller_hook.patch
patch --batch --fuzz=0 -d /out/capture-source -p1 < /tests/monado_session_events.patch
patch --batch --fuzz=0 -d /out/capture-source -p1 < /tests/monado_layer_policy.patch
args=(-S /out/capture-source -B /out/capture-build -G Ninja -DCMAKE_BUILD_TYPE=Release
    -DXRT_FEATURE_SERVICE=ON -DXRT_FEATURE_SERVICE_SYSTEMD=OFF
    -DXRT_FEATURE_OPENXR=ON -DXRT_FEATURE_OPENVR=OFF
    -DXRT_FEATURE_OPENXR_LAYER_CUBE=OFF -DXRT_FEATURE_OPENXR_LAYER_CYLINDER=ON
    -DXRT_FEATURE_OPENXR_LAYER_EQUIRECT1=OFF -DXRT_FEATURE_OPENXR_LAYER_EQUIRECT2=ON
    -DXRT_FEATURE_OPENXR_LAYER_DEPTH=OFF
    -DXRT_FEATURE_OPENXR_LAYER_COLOR_SCALE_BIAS=ON
    -DXRT_FEATURE_OPENXR_LAYER_FB_ALPHA_BLEND=OFF -DXRT_FEATURE_OPENXR_LAYER_FB_DEPTH_TEST=OFF
    -DXRT_FEATURE_OPENXR_LAYER_FB_IMAGE_LAYOUT=OFF -DXRT_FEATURE_OPENXR_LAYER_FB_PASSTHROUGH=OFF
    -DXRT_FEATURE_OPENXR_LAYER_FB_SETTINGS=OFF -DXRT_FEATURE_OPENXR_INVERTED_ALPHA=OFF
    -DXRT_MODULE_COMPOSITOR_MAIN=OFF -DXRT_MODULE_COMPOSITOR_NULL=ON
    -DXRT_FEATURE_DEBUG_GUI=OFF -DXRT_FEATURE_WINDOW_PEEK=OFF
    -DXRT_MODULE_MONADO_GUI=OFF -DBUILD_TESTING=OFF
    -DXRT_HAVE_OPENGL=OFF -DXRT_HAVE_OPENGL_GLX=OFF -DXRT_HAVE_SDL2=OFF
    -DXRT_HAVE_OPENGLES=OFF -DXRT_HAVE_EGL=OFF)
# Disable all physical-device drivers; simulated HMD is the sole test device.
while read -r driver; do args+=("-D$driver=OFF"); done < <(
    grep -oE 'XRT_BUILD_DRIVER_[A-Z0-9_]+' /source/CMakeLists.txt | sort -u)
args+=(-DXRT_BUILD_DRIVER_SIMULATED=ON)
cmake "${args[@]}"
cmake --build /out/capture-build --target monado-service openxr_monado -j 4
glslangValidator -V /tests/meteor_gpu_scene.comp -o /out/meteor_gpu_scene.spv
spirv-val /out/meteor_gpu_scene.spv
for stage in vert frag; do
    glslangValidator -V "/tests/meteor_raster_scene.$stage" -o "/out/meteor_raster_scene.$stage.spv"
    spirv-val "/out/meteor_raster_scene.$stage.spv"
done
for stage in vert frag; do
    glslangValidator -V --vn "meteor_quad_$stage" "/tests/meteor_quad.$stage" -o "/out/meteor_quad.$stage.h"
    sha256sum "/tests/meteor_quad.$stage" > "/out/meteor_quad.$stage.sha256"
done
c++ -std=c++17 -O2 -DNDEBUG -Wall -Wextra -Werror -Wno-missing-field-initializers \
    /tests/monado_runtime_probe.cpp -lopenxr_loader -lvulkan -o /out/runtime-probe
echo 'Built diagnostic capture/optional encoder-hook service and app; run the separate probes to verify each path.'
