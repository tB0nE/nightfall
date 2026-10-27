#!/usr/bin/env bash
set -euo pipefail
mkdir -p /out/run
chmod 700 /out/run
export XDG_RUNTIME_DIR=/out/run
export XR_RUNTIME_JSON=/out/capture-build/openxr_monado-dev.json
export SIMULATED_ENABLE=1 XRT_COMPOSITOR_NULL=1 XRT_NO_STDIN=1
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json
if [[ ! -f "$VK_ICD_FILENAMES" ]]; then
    export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json
fi
[[ -f "$VK_ICD_FILENAMES" ]] || { echo 'Software Vulkan manifest missing' >&2; exit 1; }
/out/capture-build/src/xrt/targets/service/monado-service > /out/service.log 2>&1 &
service_pid=$!
trap 'kill "$service_pid" 2>/dev/null || true; wait "$service_pid" 2>/dev/null || true' EXIT
ready=0
for attempt in {1..100}; do
    kill -0 "$service_pid" || { tail -40 /out/service.log; exit 1; }
    if [[ -S /out/run/monado_comp_ipc ]]; then ready=1; break; fi
    sleep 0.1
done
[[ "$ready" == 1 ]] || { echo 'Service socket did not become ready' >&2; exit 1; }
# Remove only known diagnostic artifacts, so old captures cannot pass this run.
rm -f /out/eye-left.ppm /out/eye-right.ppm /out/server-eye-left.ppm /out/server-eye-right.ppm /out/capture-complete
timeout 20s /out/runtime-probe | tee /out/probe.log
grep -q 'METEOR_CAPTURE_OK' /out/service.log
if grep -q 'METEOR_CAPTURE_FAILED' /out/service.log; then exit 1; fi
cmp /out/eye-left.ppm /out/server-eye-left.ppm
cmp /out/eye-right.ppm /out/server-eye-right.ppm
echo 'PASS: app swapchains and server-side stereo readback; no encoder or XR stream.'
