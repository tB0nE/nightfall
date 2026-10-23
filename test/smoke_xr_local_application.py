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
import secrets


def run(root, steam_wrapper=False):
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
        wrapper = None
        try:
            if publisher.stdout.readline().strip() != "READY synthetic tracking publisher":
                raise RuntimeError("Synthetic tracking failed to start")
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("NIGHTFALL_XR_", "METEOR_XR_"))}
            # A smoke test must never inherit the user's selected Steam game.
            # Always launch our native sample through an isolated local profile.
            selection = out / "smoke-application.json"
            spec = {"argv": [str(cache / "hello-xr-spike/build/src/tests/hello_xr/hello_xr"),
                             "-g", "Vulkan2", "-s", "Stage", "-bm", "Opaque"],
                    "cwd": str(root), "launch": "manual"}
            selection.write_text(json.dumps(spec))
            env.update(NIGHTFALL_XR_APPLICATION_SPEC=str(selection),
                       NIGHTFALL_XR_GODOT_ENGINE="1", NIGHTFALL_XR_UPSTREAM_DEMO="1",
                       NIGHTFALL_XR_TRACKING_PORT=str(port), METEOR_XR_TRACKED_SCENE="1",
                       NIGHTFALL_XR_HEADSET_OPTICS="1", NIGHTFALL_XR_PROBE_FRAMES="1200",
                       NIGHTFALL_XR_EYE_SIZE="1024", NIGHTFALL_XR_TARGET_HZ="60",
                       NIGHTFALL_XR_FREE_RUNNING="1", NIGHTFALL_XR_PROBE_OUTPUT=str(out),
                       NIGHTFALL_XR_ASYNC_ENCODE="1", NIGHTFALL_XR_ASYNC_DELIVERY="1",
                       NIGHTFALL_XR_TRANSPORT_RECEIVER=str(receiver),
                       NIGHTFALL_XR_CONTROLLERS="1", NIGHTFALL_XR_CONTROLLER_PROFILE="touch",
                       NIGHTFALL_XR_TOUCH_INPUTS="1")
            if steam_wrapper:
                spec.update(launch="steam",steam_app_id="438100")
                selection=out/"steam-application.json"
                selection.write_text(json.dumps(spec))
                env["NIGHTFALL_XR_APPLICATION_SPEC"]=str(selection)
                env["NIGHTFALL_XR_RUNTIME_GENERATION"]=secrets.token_hex(16)
            with (out / "smoke.log").open("w") as log:
                probe = subprocess.Popen(["bash", str(root / "tools/build_support/probe_monado_nvenc.sh")],
                                         env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                deadline = time.monotonic() + 25
                armed_since = None
                idle_start = None
                requested = False
                while True:
                    ready = out / "application-ready.json"
                    if ready.exists() and not requested:
                        if armed_since is None:
                            armed_since = time.monotonic()
                            state = json.loads((out / "runtime-state.json").read_text())
                            pid = state["pid"]
                            idle_start = (pid, Path(f"/proc/{pid}/stat").read_text())
                        if time.monotonic() - armed_since >= 3:
                            text = (out / "service.log").read_text()
                            if "METEOR_ENCODER_INIT" in text or "METEOR_ENCODE_OK" in text or (out / "monado-stereo.jsonl").exists():
                                raise RuntimeError("Armed runtime rendered/encoded before application launch")
                            pid, before = idle_start
                            after = Path(f"/proc/{pid}/stat").read_text()
                            def ticks(value):
                                fields = value.rsplit(")",1)[1].split()
                                return int(fields[11])+int(fields[12])
                            elapsed = time.monotonic()-armed_since
                            rss = int(Path(f"/proc/{pid}/statm").read_text().split()[1])*os.sysconf("SC_PAGE_SIZE")
                            result = {"seconds":elapsed,"runtime_cpu_percent_one_core":100*(ticks(after)-ticks(before))/os.sysconf("SC_CLK_TCK")/elapsed,"runtime_rss_mib":rss/1048576,"encoded_before_launch":0}
                            (out / "armed-idle.json").write_text(json.dumps(result,indent=2)+"\n")
                            print("Armed idle sample:",json.dumps(result),flush=True)
                            if steam_wrapper:
                                # Real wrapper/owned-runner path with a native sample,
                                # not a claim that Steam/Proton or VRChat ran.
                                wrapper=subprocess.Popen([sys.executable,str(root/"tools/meteor_xr.py"),"steam-run","--app-id","438100","--session",str(out),"--",*spec["argv"]],cwd=spec["cwd"])
                            else:
                                subprocess.run([sys.executable,str(root / "tools/meteor_xr.py"),"launch","--session",str(out)],check=True)
                            requested = True
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
            if wrapper and wrapper.wait(timeout=5)!=130:
                raise RuntimeError("Steam wrapper did not report the intentional interruption")
            outcome = json.loads((out / "lifecycle-outcome.json").read_text())
            assert outcome["outcome"] == "interrupted" and outcome["encoded_frames"] >= 60
            print(f"PASS: external app captured {outcome['encoded_frames']} frames with synthetic tracking; intentionally interrupted")
        finally:
            if wrapper and wrapper.poll() is None:
                wrapper.terminate()
                wrapper.wait(timeout=3)
            if probe and probe.poll() is None:
                os.killpg(probe.pid, signal.SIGTERM)
                try: probe.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(probe.pid, signal.SIGKILL)
                    probe.wait()
            publisher.terminate()
            publisher.communicate(timeout=3)


if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve(), "--steam-wrapper" in sys.argv[2:])
