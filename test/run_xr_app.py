"""Run any OpenXR app under Meteor's XR runtime, without a headset.

The runtime is the real one (Monado with Meteor's capture hook and encoder).
A synthetic publisher stands in for the headset's tracking, holding the head
and controllers still, and a local receiver takes the encoded video. The app's
frames land in <session>/monado-stereo.h264, so its 3D view can be inspected.

    with XrAppSession(root, ["hello_xr", "-g", "Vulkan2"], runtime=...) as session:
        session.wait_frames(60)
        ...  # drive the app, read session.dir
    # the client disconnects and everything stops

Used by tools/verify.py (xr). test/smoke_xr_local_application.py is the
original single-shot version.
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path



class XrAppSession:
    def __init__(self, root, argv, cwd=None, runtime=None, encoder="nvenc", eye_size=1024, hz=60):
        self.root = Path(root)
        self.argv = [str(a) for a in argv]
        self.cwd = str(cwd or root)
        self.runtime = Path(runtime) if runtime else None
        self.encoder = encoder
        self.eye_size = eye_size
        self.hz = hz
        self.processes = []
        self.dir = None

    def _build_helpers(self):
        endpoint = self.dir / "publisher"
        subprocess.run(["c++", "-std=c++17", "-O2", "-pthread",
                        "-I" + str(self.root / "extensions/nightfall-xr/include"),
                        str(self.root / "test/pcvr_meteor_tracking_endpoint_test.cpp"),
                        str(self.root / "extensions/nightfall-xr/src/pcvr_meteor_tracking_endpoint.cpp"),
                        "-o", str(endpoint)], check=True)
        receiver = self.dir / "receiver"
        subprocess.run(["rustc", "--edition=2024", "-O", str(self.root / "meteor/tools/xr_transport_receiver.rs"),
                        "-o", str(receiver)], check=True)
        return endpoint, receiver

    def __enter__(self):
        cache = self.root / ".build-cache/meteor-xr"
        self.dir = Path(tempfile.mkdtemp(prefix="xr-app-", dir=cache))
        endpoint, receiver = self._build_helpers()
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        # Two arguments: a still head and controllers, triggers below a click.
        publisher = subprocess.Popen([str(endpoint), str(port)], stdout=subprocess.PIPE, text=True)
        self.processes.append(publisher)
        if publisher.stdout.readline().strip() != "READY synthetic tracking publisher":
            raise RuntimeError("synthetic tracking failed to start")
        spec = self.dir / "application.json"
        spec.write_text(json.dumps({"argv": self.argv, "cwd": self.cwd, "launch": "manual"}))
        env = {k: v for k, v in os.environ.items() if not k.startswith(("NIGHTFALL_XR_", "METEOR_XR_"))}
        env.update(NIGHTFALL_XR_APPLICATION_SPEC=str(spec), NIGHTFALL_XR_GODOT_ENGINE="1",
                   NIGHTFALL_XR_UPSTREAM_DEMO="1", NIGHTFALL_XR_TRACKING_PORT=str(port),
                   METEOR_XR_TRACKED_SCENE="1", NIGHTFALL_XR_HEADSET_OPTICS="1",
                   NIGHTFALL_XR_PROBE_FRAMES="18000", NIGHTFALL_XR_EYE_SIZE=str(self.eye_size),
                   NIGHTFALL_XR_TARGET_HZ=str(self.hz), NIGHTFALL_XR_FREE_RUNNING="1",
                   NIGHTFALL_XR_PROBE_OUTPUT=str(self.dir), NIGHTFALL_XR_ASYNC_ENCODE="1",
                   NIGHTFALL_XR_ASYNC_DELIVERY="1", NIGHTFALL_XR_TRANSPORT_RECEIVER=str(receiver),
                   NIGHTFALL_XR_CONTROLLERS="1", NIGHTFALL_XR_CONTROLLER_PROFILE="touch",
                   NIGHTFALL_XR_TOUCH_INPUTS="1", NIGHTFALL_XR_ENCODER_BACKEND=self.encoder)
        launcher = ([sys.executable, str(self.runtime / "tools/meteor_xr_runtime.py")] if self.runtime
                    else ["bash", str(self.root / "tools/build_support/probe_monado_nvenc.sh")])
        self.log = open(self.dir / "session.log", "w")
        self.probe = subprocess.Popen(launcher, env=env, stdout=self.log, stderr=subprocess.STDOUT,
                                      start_new_session=True)
        deadline = time.monotonic() + 30
        while not (self.dir / "application-ready.json").exists():
            if self.probe.poll() is not None or time.monotonic() > deadline:
                self.__exit__(None, None, None)
                raise RuntimeError(f"the XR runtime didn't arm; see {self.dir / 'service.log'}")
            time.sleep(0.1)
        tools = self.runtime or self.root
        subprocess.run([sys.executable, str(tools / "tools/meteor_xr.py"), "launch", "--session", str(self.dir)],
                       check=True, capture_output=True)
        return self

    def frames(self):
        ledger = self.dir / "monado-stereo.jsonl"
        return len(ledger.read_text().splitlines()) if ledger.exists() else 0

    def wait_frames(self, count, timeout=60):
        deadline = time.monotonic() + timeout
        while self.frames() < count:
            if self.probe.poll() is not None:
                raise RuntimeError(f"the XR runtime exited; see {self.dir / 'service.log'}")
            if time.monotonic() > deadline:
                raise TimeoutError(f"{self.frames()} of {count} frames after {timeout} s")
            time.sleep(0.1)

    def service_log(self):
        path = self.dir / "service.log"
        return path.read_text(errors="replace") if path.exists() else ""

    def __exit__(self, *_):
        if self.dir and getattr(self, "probe", None) and self.probe.poll() is None:
            (self.dir / "client-disconnected").write_text("session complete\n")
            try:
                self.probe.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.probe.pid, signal.SIGTERM)
                try:
                    self.probe.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(self.probe.pid, signal.SIGKILL)
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
        if getattr(self, "log", None):
            self.log.close()


def nightfall_argv(root, godot, data_dir, bridge_port, gpu="10de:2204", extra=()):
    """Nightfall in a headless gamescope with its own user data and the bridge
    on. gamescope runs on `gpu` (vendor:device, the runtime compositor's GPU),
    so the app's window can present there; OpenXR picks the app's GPU."""
    # The runtime runs only an absolute executable path.
    return [shutil.which("gamescope"), "--backend", "headless", "--prefer-vk-device", gpu,
            "-W", "1280", "-H", "720", "--",
            shutil.which("env"), f"XDG_DATA_HOME={data_dir}", f"XDG_CONFIG_HOME={data_dir}/config",
            godot, "--xr-mode", "on", "--path", str(root), "--",
            "--nf-dev-bridge", f"--nf-dev-bridge-port={bridge_port}", *extra]
