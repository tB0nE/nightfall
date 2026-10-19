"""Isolated Linux/NVIDIA runtime test with a synthetic USB tracking publisher."""
import os
import re
from pathlib import Path
import socket
import subprocess
import sys
import json
import math


def run(root):
    out = root / ".build-cache/meteor-xr/tracking-runtime-spike"
    out.mkdir(parents=True, exist_ok=True)
    frames = int(os.environ.get("NIGHTFALL_XR_PROBE_FRAMES", "32"))
    if not 1 <= frames <= 240:
        raise ValueError("Frame count must be 1..240")
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
        env = dict(os.environ, NIGHTFALL_XR_TRACKING_PORT=str(port), NIGHTFALL_XR_PROBE_FRAMES=str(frames),
                   METEOR_XR_TRACKED_SCENE="1")
        for key in ("NIGHTFALL_XR_DEVICE_PORT", "NIGHTFALL_XR_TRANSPORT_RECEIVER", "NIGHTFALL_XR_PROBE_ABORT"):
            env.pop(key, None)
        if env.get("NIGHTFALL_XR_ASYNC_DELIVERY") == "1":
            receiver = out / "receiver"
            subprocess.run(["rustc", "--edition=2024", "-O",
                            str(root / "meteor/tools/xr_transport_receiver.rs"), "-o", str(receiver)], check=True)
            env["NIGHTFALL_XR_TRANSPORT_RECEIVER"] = str(receiver)
        result = subprocess.run(["bash", str(root / "tools/build_support/probe_monado_nvenc.sh")],
                                env=env, timeout=60, capture_output=True, text=True)
        (out / "probe.log").write_text(result.stdout + result.stderr)
        result.check_returncode()
        app_log = (root / ".build-cache/meteor-xr/monado-nvenc-spike/probe.log").read_text()
        positions = [float(x) for x in re.findall(r"Tracked view frame=\d+ left_position=([-0-9.]+),", app_log)]
        independent=env.get("NIGHTFALL_XR_HELLO_XR")=="1"
        if independent:
            encoded=[json.loads(line) for line in (root / ".build-cache/meteor-xr/monado-nvenc-spike/monado-stereo.jsonl").read_text().splitlines()]
            positions=[r["views"][0]["position"][0] for r in encoded]
        if (not independent and len(positions)!=frames) or not positions or max(positions)-min(positions) < .005:
            raise RuntimeError("Injected changing poses did not reach application xrLocateViews")
        centers = [tuple(map(float, xyz)) for xyz in re.findall(r"Tracked center=([-0-9.]+),([-0-9.]+),([-0-9.]+)", app_log)]
        if independent:
            centers=[tuple((a+b)*.5 for a,b in zip(r["views"][0]["position"],r["views"][1]["position"])) for r in encoded]
        if (not independent and len(centers)!=frames) or not centers or any(not (.19 < x < .31 and abs(y)<.001 and abs(z)<.001) for x,y,z in centers):
            raise RuntimeError("Host STAGE did not preserve the explicitly adopted Quest LOCAL origin")
        if env.get("NIGHTFALL_XR_HEADSET_OPTICS")=="1":
            records=[json.loads(line) for line in (root / ".build-cache/meteor-xr/monado-nvenc-spike/monado-stereo.jsonl").read_text().splitlines()]
            for record in records:
                views=record["views"]
                if not math.isclose(math.dist(views[0]["position"],views[1]["position"]),.064,abs_tol=1e-5):
                    raise RuntimeError("Negotiated eye spacing did not reach rendered views")
                for eye,expected in zip(views,[[-.8,.7,.75,-.65],[-.7,.8,.75,-.65]]):
                    if any(not math.isclose(a,b,abs_tol=1e-5) for a,b in zip(eye["fov"],expected)):
                        raise RuntimeError("Negotiated asymmetric FOV did not reach rendered views")
            print("PASS: negotiated asymmetric FOV and 64 mm eye spacing reached actual encoded render metadata")
        if env.get("NIGHTFALL_XR_CONTROLLERS")=="1":
            for hand in (0,1):
                states=[tuple(map(float,values)) for values in re.findall(
                    rf"HELLO_XR_HAND hand={hand} position=([-0-9.]+),([-0-9.]+),([-0-9.]+) scale=([0-9.]+)",app_log)]
                if len(states)<2 or max(s[0] for s in states)-min(s[0] for s in states)<.005:
                    raise RuntimeError("Remote controller motion did not reach sample hand rendering")
                if not {0.05,0.1}.issubset({round(s[3],3) for s in states}):
                    raise RuntimeError("Remote squeeze did not change sample hand cube scale")
                if any(abs(s[1]+.3)>.001 or abs(s[2]+.5)>.001 for s in states):
                    raise RuntimeError("Remote controller coordinates do not match adopted root")
                center=.05 if hand==0 else .45
                if any(abs(s[0]-center)>.031 for s in states):
                    raise RuntimeError("Remote left/right controller identities are swapped")
            print("PASS: both remote controllers moved and squeeze changed actual hello_xr hand cubes")
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
