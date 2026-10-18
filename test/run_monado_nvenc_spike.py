"""Actual Monado swapchain -> GPU stereo pack -> NVENC diagnostic, Linux only."""
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import tempfile
import fcntl

from check_nvenc_stereo import validate


def run(root: Path, out: Path):
    # Linux sockaddr_un is limited to 108 bytes, shorter than this checkout path.
    with (out / "probe.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix="nf-xr-", dir="/tmp") as socket_dir:
            run_isolated(root, out, Path(socket_dir))


def run_isolated(root: Path, out: Path, runtime: Path):
    abort_test = os.environ.get("NIGHTFALL_XR_PROBE_ABORT") == "1"
    frame_count = int(os.environ.get("NIGHTFALL_XR_PROBE_FRAMES", "32"))
    if not 1 <= frame_count <= 240:
        raise ValueError("NIGHTFALL_XR_PROBE_FRAMES must be 1..240")
    if abort_test and frame_count < 16:
        raise ValueError("Disconnect test requires at least 16 requested frames")
    build = root / ".build-cache/meteor-xr/monado-linux-spike"
    service = build / "capture-build/src/xrt/targets/service/monado-service"
    library = build / "capture-build/src/xrt/targets/openxr/libopenxr_monado.so"
    app = build / "runtime-probe"
    for executable in (service, library, app):
        if not executable.is_file():
            raise RuntimeError("Run probe_monado_runtime.sh --build first")
    icd = Path("/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json")
    if not icd.is_file():
        raise RuntimeError("NVIDIA ICD absent; no software fallback")
    runtime.chmod(0o700)
    for name in ("capture-complete", "monado-stereo.h264", "monado-stereo.json", "monado-stereo.jsonl", "decoded.rgb",
                 "server-eye-left.ppm", "server-eye-right.ppm"):
        (out / name).unlink(missing_ok=True)
    manifest = out / "runtime.json"
    manifest.write_text(json.dumps({"file_format_version": "1.0.0", "runtime": {
        "name": "Meteor diagnostic Monado", "library_path": str(library)}}))
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XR_RUNTIME_JSON=str(manifest),
               SIMULATED_ENABLE="1", XRT_COMPOSITOR_NULL="1", XRT_NO_STDIN="1",
               VK_ICD_FILENAMES=str(icd), VK_DRIVER_FILES=str(icd),
               METEOR_CONTINUOUS_FRAMES=str(frame_count),
               METEOR_PROBE_OUTPUT=str(out), METEOR_NVENC_BRIDGE=str(out / "libmeteor-nvenc-probe.so"))
    with (out / "service.log").open("w") as log:
        child = subprocess.Popen([str(service)], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 10
            while not (runtime / "monado_comp_ipc").is_socket():
                if child.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError(f"Service startup failed; see {out / 'service.log'}")
                time.sleep(0.05)
            if abort_test:
                application = subprocess.Popen([str(app)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 15
                    while True:
                        ledger = out / "monado-stereo.jsonl"
                        if ledger.exists() and len(ledger.read_text().splitlines()) >= 5:
                            break
                        if application.poll() is not None or time.monotonic() > deadline:
                            raise RuntimeError("No active encoder frames before disconnect test")
                        time.sleep(0.005)
                finally:
                    if application.poll() is None:
                        application.kill()  # Exact child deliberately simulates an app crash.
                    stdout, stderr = application.communicate(timeout=5)
                result = subprocess.CompletedProcess([str(app)], application.returncode, stdout, stderr)
            else:
                result = subprocess.run([str(app)], env=env, timeout=40, capture_output=True, text=True)
            (out / "probe.log").write_text(result.stdout + result.stderr)
            if not abort_test:
                result.check_returncode()
            if child.poll() is not None:
                raise RuntimeError("Service exited unexpectedly")
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
    text = (out / "service.log").read_text()
    if "METEOR_ENCODE_OK" not in text or "METEOR_CAPTURE_FAILED" in text:
        raise RuntimeError("Encoder bridge did not acknowledge output")
    if "METEOR_CAPTURE_EYE" in text or (out / "server-eye-left.ppm").exists():
        raise RuntimeError("CPU readback path unexpectedly ran")
    records = [json.loads(line) for line in (out / "monado-stereo.jsonl").read_text().splitlines()]
    expected_times = [int(value) for value in re.findall(r"Frame \d+ monotonic_ns=(\d+)", result.stdout)]
    if abort_test:
        if not 5 <= len(records) < frame_count or len(expected_times) < len(records):
            raise RuntimeError("Disconnect test did not interrupt an active sequence")
        frame_count = len(records)
        expected_times = expected_times[:frame_count]
    if len(records) != frame_count or len(expected_times) != frame_count:
        raise RuntimeError("Missing or duplicated frames")
    offset, last_frame, last_time = 0, 0, 0
    for metadata, expected_time in zip(records, expected_times):
        if metadata["display_time_ns"] != expected_time or expected_time <= last_time:
            raise RuntimeError("Encoded display timestamps do not match submitted frame order")
        if metadata["frame_id"] <= last_frame or (metadata["width"], metadata["height"]) != (512, 256):
            raise RuntimeError("Invalid output frame metadata")
        if metadata["offset"] != offset or metadata["bytes"] <= 0:
            raise RuntimeError("Invalid bitstream frame boundaries")
        offset += metadata["bytes"]
        last_frame, last_time = metadata["frame_id"], expected_time
        if len(metadata["views"]) != 2:
            raise RuntimeError("Missing stereo views")
        for view in metadata["views"]:
            if not all(math.isfinite(v) for key in ("position", "orientation", "fov") for v in view[key]):
                raise RuntimeError("Invalid view metadata")
            if abs(sum(v*v for v in view["orientation"]) - 1) > 0.001:
                raise RuntimeError("Invalid orientation")
            left, right, up, down = view["fov"]
            if not (left < right and down < up):
                raise RuntimeError("Invalid FOV")
    if offset != (out / "monado-stereo.h264").stat().st_size:
        raise RuntimeError("Unaccounted bitstream bytes")
    if (text.count("METEOR_ENCODER_INIT") != 1 or
            f"METEOR_ENCODER_DRAIN frames={frame_count} " not in text or
            text.count("METEOR_ENCODER_RELEASED") != 1):
        raise RuntimeError("Encoder was not initialized once and drained cleanly")
    subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                    "-i", str(out / "monado-stereo.h264"), "-pix_fmt", "rgb24", "-f", "rawvideo",
                    str(out / "decoded.rgb")], check=True, timeout=20)
    validate((out / "decoded.rgb").read_bytes(), frames=frame_count, greens=[(i * 73) % 256 for i in range(frame_count)])
    label = "unexpected app disconnect" if abort_test else "normal session exit"
    print(f"PASS: {frame_count} changing Monado frames; one persistent encoder/surface; decoded markers, timestamps and bitstream ranges match; clean drain after {label}")
    print(f"Artifacts: {out}")


if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
