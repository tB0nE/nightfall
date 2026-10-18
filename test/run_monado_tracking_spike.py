"""Isolated Linux/NVIDIA runtime test with a synthetic USB tracking publisher."""
import os
import re
from pathlib import Path
import socket
import subprocess
import sys


def run(root):
    out = root / ".build-cache/meteor-xr/tracking-runtime-spike"
    out.mkdir(parents=True, exist_ok=True)
    endpoint = out / "synthetic-publisher"
    subprocess.run(["c++", "-std=c++17", "-O2", "-pthread", "-Wall", "-Wextra", "-Werror",
                    "-I" + str(root / "extensions/nightfall-xr/include"),
                    str(root / "test/pcvr_meteor_tracking_endpoint_test.cpp"),
                    str(root / "extensions/nightfall-xr/src/pcvr_meteor_tracking_endpoint.cpp"),
                    "-o", str(endpoint)], check=True)
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    publisher = subprocess.Popen([str(endpoint), str(port), "moving"], stdout=subprocess.PIPE, text=True)
    try:
        if publisher.stdout.readline().strip() != "READY synthetic tracking publisher":
            raise RuntimeError("Tracking publisher not ready")
        env = dict(os.environ, NIGHTFALL_XR_TRACKING_PORT=str(port), NIGHTFALL_XR_PROBE_FRAMES="32",
                   METEOR_XR_TRACKED_SCENE="1")
        for key in ("NIGHTFALL_XR_DEVICE_PORT", "NIGHTFALL_XR_TRANSPORT_RECEIVER", "NIGHTFALL_XR_PROBE_ABORT"):
            env.pop(key, None)
        result = subprocess.run(["bash", str(root / "tools/build_support/probe_monado_nvenc.sh")],
                                env=env, timeout=60, capture_output=True, text=True)
        (out / "probe.log").write_text(result.stdout + result.stderr)
        result.check_returncode()
        app_log = (root / ".build-cache/meteor-xr/monado-nvenc-spike/probe.log").read_text()
        positions = [float(x) for x in re.findall(r"Tracked view frame=\d+ left_position=([-0-9.]+),", app_log)]
        if len(positions) != 32 or max(positions)-min(positions) < .005:
            raise RuntimeError("Injected changing poses did not reach application xrLocateViews")
        centers = [tuple(map(float, xyz)) for xyz in re.findall(r"Tracked center=([-0-9.]+),([-0-9.]+),([-0-9.]+)", app_log)]
        if len(centers) != 32 or any(not (.19 < x < .31 and abs(y)<.001 and abs(z)<.001) for x,y,z in centers):
            raise RuntimeError("Host STAGE did not preserve the explicitly adopted Quest LOCAL origin")
        if publisher.wait(timeout=5):
            raise RuntimeError("Tracking bridge did not close the publisher cleanly")
        print(result.stdout)
        print("PASS: changing poses reached Monado HMD and application xrLocateViews; synthetic publisher, not headset/world-lock proof")
    finally:
        if publisher.poll() is None:
            publisher.terminate()
            publisher.wait(timeout=5)
        publisher.stdout.close()


if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve())
