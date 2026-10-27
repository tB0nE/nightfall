"""Run built controller probes on the host GPU in a private Monado runtime."""
import json
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
from xr_runtime_lifecycle import managed_runtime


def main():
    root=Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xrizer', type=Path, default=root / '.build-cache/meteor-xr/xrizer-package/runtime/bin/linux64/vrclient.so')
    args = parser.parse_args()
    xrizer = args.xrizer.resolve(strict=True)
    build=root / ".build-cache/meteor-xr/monado-linux-spike"
    output=Path(tempfile.mkdtemp(prefix="controller-host-",dir=build))
    # Unix-domain socket paths have a 108-byte limit; checkout paths are long.
    runtime=Path(tempfile.mkdtemp(prefix="nf-input-"))
    runtime.chmod(0o700)
    manifest=output / "runtime.json"
    manifest.write_text(json.dumps({"file_format_version":"1.0.0","runtime":{
        "library_path":str(build / "capture-build/src/xrt/targets/openxr/libopenxr_monado.so")}}))
    buttons=output / "buttons"
    buttons.write_text("0 0\n")
    env=dict(os.environ)
    # The fixture and IPC namespace belong only to this diagnostic's children.
    for key in list(env):
        if key.startswith(("METEOR_","SIMULATED_","XRT_","XR_")): env.pop(key)
    env.update(XDG_RUNTIME_DIR=str(runtime),XR_RUNTIME_JSON=str(manifest),
               SIMULATED_ENABLE="1",XRT_COMPOSITOR_NULL="1",XRT_NO_STDIN="1",
               SIMULATED_LEFT="touch",SIMULATED_RIGHT="touch",
               METEOR_XR_CONTROLLERS="1",METEOR_XR_TOUCH_INPUTS="1",
               METEOR_TRACKING_BRIDGE=str(build / "controller-fixture.so"),METEOR_TRACKING_PORT="1",
               METEOR_CONTROLLER_FIXTURE=str(buttons),
               METEOR_PROBE_OUTPUT=str(output),
               VK_ICD_FILENAMES="/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json",
               VK_DRIVER_FILES="/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json",
               METEOR_XRIZER_LIBRARY=str(xrizer),
               METEOR_VRCHAT_MANIFEST="/run/media/system/GAMES/SteamLibrary/steamapps/common/VRChat/VRChat_Data/StreamingAssets/SteamVR/actions.json")
    with managed_runtime([str(build / "capture-build/src/xrt/targets/service/monado-service")],
                         env=env,ready_path=runtime / "monado_comp_ipc",log_path=output / "service.log",
                         state_path=output / "state.json"):
        for name in ("controller-input-probe","openvr-controller-input-probe"):
            with (output / f"{name}.log").open("w") as log:
                result=subprocess.run([str(build / name)],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=30)
            print(f"{name}: exit={result.returncode}; {output / f'{name}.log'}",flush=True)
            if result.returncode: raise RuntimeError(f"Controller probe failed; see {output}")
    print(f"PASS: real OpenXR and installed xrizer input paths: {output}")


if __name__=="__main__": main()
