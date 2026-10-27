#!/usr/bin/env bash
# Validate packaged Python and ELF loading with only the declared baseline OS libraries.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="$(cd "${1:?Pass the verified runtime bundle directory}" && pwd)"
ENGINE="${NIGHTFALL_CONTAINER_ENGINE:-docker}"
IMAGE=nightfall-meteor-xr-runtime-check:ubuntu22.04
"$ENGINE" build -t "$IMAGE" -f "$ROOT/tools/build_support/Dockerfile.meteor-xr-runtime-check" "$ROOT/tools/build_support"
"$ENGINE" run --rm --network none --read-only --tmpfs /tmp --cap-drop ALL \
    --security-opt no-new-privileges --user "$(id -u):$(id -g)" \
    -v "$BUNDLE:/bundle:ro" -e LD_LIBRARY_PATH=/bundle/xr-runtime/lib \
    "$IMAGE" python3 -c '
import ctypes,json,pathlib,subprocess,sys
root=pathlib.Path("/bundle")
sys.path.insert(0,str(root/"tools"))
from meteor_xr_runtime import validate
manifest=validate(root)
for relative in manifest["sha256"]:
    path=root/relative
    if path.suffix==".py": compile(path.read_text(),str(path),"exec")
for relative in [
    ".build-cache/meteor-xr/monado-linux-spike/capture-build/src/xrt/targets/openxr/libopenxr_monado.so",
    "xr-runtime/libmeteor-tracking-probe.so", "xr-runtime/libmeteor-nvenc-probe.so"]:
    ctypes.CDLL(str(root/relative))
if "vaapi" in manifest.get("backends",[]):
    ctypes.CDLL(str(root/"xr-runtime/libmeteor-vaapi-probe.so"))
    ffmpeg=ctypes.CDLL(str(root/"xr-runtime/encoder-lib/libavcodec.so.62"))
    ffmpeg.avcodec_find_encoder_by_name.argtypes=[ctypes.c_char_p]
    ffmpeg.avcodec_find_encoder_by_name.restype=ctypes.c_void_p
    if not ffmpeg.avcodec_find_encoder_by_name(b"hevc_vaapi"): raise RuntimeError("Packaged FFmpeg lacks HEVC VA-API encoding")
if manifest.get("openvr_compat"):
    ctypes.CDLL(str(root/manifest["openvr_compat"]/"bin/linux64/vrclient.so"))
service=root/".build-cache/meteor-xr/monado-linux-spike/capture-build/src/xrt/targets/service/monado-service"
result=subprocess.check_output(["ldd",str(service)],text=True)
if "not found" in result: raise RuntimeError(result)
if "/bundle/xr-runtime/lib/libcjson.so.1" not in result: raise RuntimeError("Private cJSON was not selected")
subprocess.run([sys.executable,str(root/"tools/meteor_xr_runtime.py"),"--check"],check=True)
print("Baseline runtime loading passed: Python, Monado, bridges and private cJSON. No GPU or gameplay tested.")
'
