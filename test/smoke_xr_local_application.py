"""Linux/NVIDIA external-app smoke: synthetic poses, real runtime and encoding.

No headset required. This deliberately interrupts after sixty encoded frames;
it proves startup/capture, not completed-stream drain or physical presentation.
"""
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
from contextlib import nullcontext
import time


def run(root):
    cache = root / ".build-cache/meteor-xr"
    with nullcontext(tempfile.mkdtemp(prefix="external-smoke-", dir=cache)) as directory:
        out = Path(directory)
        print(f"Smoke diagnostics: {out}", flush=True)
        endpoint = out / "publisher"
        subprocess.run(["c++", "-std=c++17", "-O2", "-pthread",
                        "-I" + str(root / "extensions/nightfall-xr/include"),
                        str(root / "test/pcvr_meteor_tracking_endpoint_test.cpp"),
                        str(root / "extensions/nightfall-xr/src/pcvr_meteor_tracking_endpoint.cpp"),
                        "-o", str(endpoint)], check=True)
        receiver = out / "receiver"
        subprocess.run(["rustc", "--edition=2024", "-O",
                        str(root / "meteor/tools/xr_transport_receiver.rs"),
                        "-o", str(receiver)], check=True)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        publisher = subprocess.Popen([str(endpoint), str(port), "moving"], stdout=subprocess.PIPE, text=True)
        probe = None
        try:
            if publisher.stdout.readline().strip() != "READY synthetic tracking publisher":
                raise RuntimeError("Synthetic tracking failed to start")
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("NIGHTFALL_XR_", "METEOR_XR_"))}
            env.update(NIGHTFALL_XR_APPLICATION_SPEC=str(cache / "application.json"),
                       NIGHTFALL_XR_GODOT_ENGINE="1", NIGHTFALL_XR_UPSTREAM_DEMO="1",
                       NIGHTFALL_XR_TRACKING_PORT=str(port), METEOR_XR_TRACKED_SCENE="1",
                       NIGHTFALL_XR_HEADSET_OPTICS="1", NIGHTFALL_XR_PROBE_FRAMES="1200",
                       NIGHTFALL_XR_EYE_SIZE="1024", NIGHTFALL_XR_TARGET_HZ="60",
                       NIGHTFALL_XR_FREE_RUNNING="1", NIGHTFALL_XR_PROBE_OUTPUT=str(out),
                       NIGHTFALL_XR_ASYNC_ENCODE="1", NIGHTFALL_XR_ASYNC_DELIVERY="1",
                       NIGHTFALL_XR_TRANSPORT_RECEIVER=str(receiver),
                       NIGHTFALL_XR_CONTROLLERS="1", NIGHTFALL_XR_CONTROLLER_PROFILE="touch",
                       NIGHTFALL_XR_TOUCH_INPUTS="1")
            with (out / "smoke.log").open("w") as log:
                probe = subprocess.Popen(["bash", str(root / "tools/build_support/probe_monado_nvenc.sh")],
                                         env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                deadline = time.monotonic() + 25
                while True:
                    ledger = out / "monado-stereo.jsonl"
                    if ledger.exists() and len(ledger.read_text().splitlines()) >= 60:
                        break
                    if probe.poll() is not None or time.monotonic() >= deadline:
                        for name in ("smoke.log", "service.log", "probe.log"):
                            path = out / name
                            if path.exists(): print(path.read_text()[-10000:])
                        raise RuntimeError("No sixty-frame external application capture")
                    time.sleep(.05)
                (out / "client-disconnected").write_text("smoke complete\n")
                probe.wait(timeout=10)
            if probe.returncode:
                raise RuntimeError((out / "smoke.log").read_text())
            outcome = json.loads((out / "lifecycle-outcome.json").read_text())
            assert outcome["outcome"] == "interrupted" and outcome["encoded_frames"] >= 60
            print(f"PASS: external app captured {outcome['encoded_frames']} frames with synthetic tracking; intentionally interrupted")
        finally:
            if probe and probe.poll() is None:
                os.killpg(probe.pid, signal.SIGTERM)
                try: probe.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(probe.pid, signal.SIGKILL)
                    probe.wait()
            publisher.terminate()
            publisher.communicate(timeout=3)


if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve())
