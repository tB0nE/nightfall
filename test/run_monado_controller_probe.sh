#!/usr/bin/env bash
# Run in the isolated Monado build image. No headset or global runtime changes.
set -euo pipefail
c++ -std=c++17 -O2 -fPIC -shared /tests/meteor_controller_fixture.cpp -o /out/controller-fixture.so
c++ -std=c++17 -O2 -DNDEBUG -Wall -Wextra -Werror -Wno-missing-field-initializers \
    /tests/monado_runtime_probe.cpp -lopenxr_loader -lvulkan -o /out/controller-input-probe
controller_run=$(mktemp -d /out/controller-input-XXXXXX)
chmod 700 "$controller_run"
export XDG_RUNTIME_DIR="$controller_run"
export XR_RUNTIME_JSON=/out/capture-build/openxr_monado-dev.json
export SIMULATED_ENABLE=1 XRT_COMPOSITOR_NULL=1 XRT_NO_STDIN=1
export SIMULATED_LEFT=touch SIMULATED_RIGHT=touch
export METEOR_XR_CONTROLLERS=1 METEOR_XR_TOUCH_INPUTS=1
export METEOR_TRACKING_BRIDGE=/out/controller-fixture.so METEOR_TRACKING_PORT=1
export METEOR_CONTROLLER_FIXTURE="$controller_run/buttons"
printf '0 0\n' > "$METEOR_CONTROLLER_FIXTURE"
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
if [[ ! -f "$VK_ICD_FILENAMES" ]]; then
    export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json
fi
/out/capture-build/src/xrt/targets/service/monado-service > "$controller_run/service.log" 2>&1 &
controller_service=$!
trap 'kill "$controller_service" 2>/dev/null || true; wait "$controller_service" 2>/dev/null || true' EXIT
for attempt in {1..100}; do
    kill -0 "$controller_service"
    [[ -S "$controller_run/monado_comp_ipc" ]] && break
    sleep 0.1
done
timeout 30s /out/controller-input-probe | tee "$controller_run/probe.log"
if [[ -n "${METEOR_XRIZER_LIBRARY:-}" ]]; then
    c++ -std=c++17 -O2 -Wall -Wextra -Werror -I /openvr/headers -I /openvr/src \
        -Wno-missing-field-initializers /tests/meteor_openvr_input_probe.cpp -ldl -lvulkan -o /out/openvr-controller-input-probe
    timeout 30s /out/openvr-controller-input-probe | tee "$controller_run/openvr-probe.log"
fi
echo "OpenXR controller proof artifacts: $controller_run"
