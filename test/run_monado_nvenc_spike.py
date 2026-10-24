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
import statistics
import secrets

from check_nvenc_stereo import validate
from xr_transport_probe import LiveTransport
from xr_frame_accounting import match_submitted_frames
from xr_application_lifecycle import run_application
from xr_runtime_lifecycle import managed_runtime
from xr_audio_environment import host_audio_environment


def run(root: Path, out: Path):
    # Linux sockaddr_un is limited to 108 bytes, shorter than this checkout path.
    with (out / "probe.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with tempfile.TemporaryDirectory(prefix="nf-xr-", dir="/tmp") as socket_dir:
            with LiveTransport(os.environ.get("NIGHTFALL_XR_TRANSPORT_RECEIVER"), out) as transport:
                run_isolated(root, out, Path(socket_dir), transport)


def run_isolated(root: Path, out: Path, runtime: Path, transport):
    (out / "postrun-validation").unlink(missing_ok=True)
    abort_test = os.environ.get("NIGHTFALL_XR_PROBE_ABORT") == "1"
    frame_count = int(os.environ.get("NIGHTFALL_XR_PROBE_FRAMES", "32"))
    eye_size = int(os.environ.get("NIGHTFALL_XR_EYE_SIZE", "256"))
    eye_height = int(os.environ.get("NIGHTFALL_XR_EYE_HEIGHT", str(eye_size)))
    foveated = os.environ.get("NIGHTFALL_XR_FOVEATED_ENCODING", "0")
    if foveated not in ("0", "1"): raise ValueError("Foveated encoding must be 0 or 1")
    target_hz = int(os.environ.get("NIGHTFALL_XR_TARGET_HZ", "20"))
    codec = os.environ.get("NIGHTFALL_XR_CODEC", "h264")
    if codec not in ("h264", "h265"):
        raise ValueError("XR codec must be h264 or h265")
    bitrate_mbps = int(os.environ.get("NIGHTFALL_XR_BITRATE_MBPS", "0"))
    if bitrate_mbps != 0 and not 8 <= bitrate_mbps <= 160:
        raise ValueError("XR bitrate must be Auto (0) or 8..160 Mbps")
    if not all(256 <= size <= 4096 and size % 16 == 0 for size in (eye_size, eye_height)) or target_hz not in (20,60,72):
        raise ValueError("Diagnostic profiles: eye size 256..4096, multiple of 16; target rate 20/60/72")
    tracked_scene = os.environ.get("METEOR_XR_TRACKED_SCENE") == "1"
    gpu_scene = os.environ.get("NIGHTFALL_XR_GPU_SCENE") == "1"
    gpu_measure = os.environ.get("NIGHTFALL_XR_GPU_MEASURE") == "1"
    headset_optics = os.environ.get("NIGHTFALL_XR_HEADSET_OPTICS") == "1"
    raster_scene = os.environ.get("NIGHTFALL_XR_RASTER_SCENE") == "1"
    hello_xr = os.environ.get("NIGHTFALL_XR_HELLO_XR") == "1"
    godot_engine=os.environ.get("NIGHTFALL_XR_GODOT_ENGINE")=="1"
    upstream_demo=os.environ.get("NIGHTFALL_XR_UPSTREAM_DEMO")=="1"
    external_spec = os.environ.get("NIGHTFALL_XR_APPLICATION_SPEC")
    external_command = external_cwd = None
    if external_spec:
        if not (godot_engine and upstream_demo):
            raise ValueError("External applications require the managed runtime profile")
        from xr_local_application import load_application
        external_command, external_cwd = load_application(external_spec)
        print(f"XR_APPLICATION host_local={external_command[0]}", flush=True)
    if eye_size >= 1024 and not upstream_demo:
        raise ValueError("High-resolution profile requires the bounded upstream demo")
    if upstream_demo and not godot_engine:
        raise ValueError("Upstream demo requires Godot engine mode")
    expect_tracking_loss=os.environ.get("NIGHTFALL_XR_EXPECT_TRACKING_LOSS")=="1"
    if expect_tracking_loss and not (hello_xr and tracked_scene):
        raise ValueError("Tracking-loss regression requires tracked hello_xr")
    controllers=os.environ.get("NIGHTFALL_XR_CONTROLLERS")=="1"
    if godot_engine and (hello_xr or gpu_scene or raster_scene or abort_test or not tracked_scene or (controllers and not upstream_demo)):
        raise ValueError("Engine fixture requires tracked mode without internal/sample/controller/abort modes")
    controller_profile=os.environ.get("NIGHTFALL_XR_CONTROLLER_PROFILE","wmr")
    touch_inputs=os.environ.get("NIGHTFALL_XR_TOUCH_INPUTS")=="1"
    if upstream_demo and controllers and (controller_profile!="touch" or not touch_inputs):
        raise ValueError("Upstream controller test requires extended native Touch inputs")
    input_seconds=int(os.environ.get("NIGHTFALL_XR_INPUT_SECONDS","0"))
    if input_seconds and (not touch_inputs or not hello_xr or not 1<=input_seconds<=30):
        raise ValueError("Input duration requires Touch hello_xr and 1..30 seconds")
    if touch_inputs and (not controllers or controller_profile!="touch"):
        raise ValueError("Extended Touch input requires controllers and touch profile")
    if controller_profile not in ("wmr","touch") or (controller_profile=="touch" and not controllers):
        raise ValueError("Controller profile must be wmr/touch; touch requires controllers enabled")
    if controllers and not tracked_scene:
        raise ValueError("Controllers require tracked mode")
    if hello_xr and (gpu_scene or gpu_measure or raster_scene or abort_test or not tracked_scene):
        raise ValueError("hello_xr requires tracked mode, no internal renderer flags or app-abort mode")
    if raster_scene and not (gpu_scene and gpu_measure):
        raise ValueError("Raster scene requires explicit GPU scene and measurement flags")
    if headset_optics and not tracked_scene:
        raise ValueError("Headset optics requires tracked scene mode")
    if gpu_measure and not gpu_scene:
        raise ValueError("GPU measurement requires explicit GPU scene mode")
    if gpu_scene and not tracked_scene:
        raise ValueError("GPU scene requires tracked scene mode")
    free_running = os.environ.get("NIGHTFALL_XR_FREE_RUNNING") == "1"
    async_delivery = os.environ.get("NIGHTFALL_XR_ASYNC_DELIVERY") == "1"
    async_encode = os.environ.get("NIGHTFALL_XR_ASYNC_ENCODE") == "1"
    if async_encode and not (free_running and async_delivery):
        raise ValueError("Async encoding requires free-running app and asynchronous delivery")
    if async_delivery and not (os.environ.get("NIGHTFALL_XR_DEVICE_PORT") or os.environ.get("NIGHTFALL_XR_TRANSPORT_RECEIVER")):
        raise ValueError("Async delivery requires a direct loopback/USB receiver")
    if free_running:
        print("EXPERIMENT: free-running diagnostic app; image leases/final drain required; " +
              ("raw encode worker enabled" if async_encode else "GPU encoding still synchronous"), flush=True)
    submitted_count = frame_count
    if free_running and abort_test:
        raise ValueError("Free-running app-disconnect accounting is a separate pending test")
    if tracked_scene and not os.environ.get("NIGHTFALL_XR_TRACKING_PORT"):
        raise ValueError("Tracked scene requires explicit live tracking port; no simulated fallback")
    maximum = target_hz*300 if upstream_demo else 240
    if not 1 <= frame_count <= maximum:
        raise ValueError(f"NIGHTFALL_XR_PROBE_FRAMES must be 1..{maximum}")
    if abort_test and frame_count < 16:
        raise ValueError("Disconnect test requires at least 16 requested frames")
    build = root / ".build-cache/meteor-xr/monado-linux-spike"
    service = build / "capture-build/src/xrt/targets/service/monado-service"
    library = build / "capture-build/src/xrt/targets/openxr/libopenxr_monado.so"
    app = build / "runtime-probe"
    if hello_xr:
        app=root / ".build-cache/meteor-xr/hello-xr-spike/build/src/tests/hello_xr/hello_xr"
    command=[str(app)] + (["-g","Vulkan2","-s","Stage","-bm","Opaque"] if hello_xr else [])
    if godot_engine:
        app=Path(os.environ.get("NIGHTFALL_GODOT_EDITOR","/var/home/tyrone/Applications/Godot_v4.7-stable_linux.x86_64"))
        project=root / "test/fixtures/meteor_xr_godot"
        if upstream_demo and not external_spec:
            from prepare_xr_upstream_demo import prepare
            project=prepare(root)
            import_start=time.monotonic()
            imported=subprocess.run([str(app),"--headless","--xr-mode","off","--editor","--import",
                            "--path",str(project)],timeout=60,capture_output=True,text=True)
            (out / "godot-import.log").write_text(imported.stdout+imported.stderr)
            imported.check_returncode()
            print(f"XR_STARTUP import_ms={(time.monotonic()-import_start)*1000:.1f}",flush=True)
        command=[str(app),"--path",str(project),"--display-driver","x11",
            "--rendering-method","mobile","--rendering-driver","vulkan","--xr-mode","on",
            "--audio-driver","Dummy","--resolution","320x180","--position","24,24"]
    if external_spec:
        command = external_command
        app = Path(command[0])
    for executable in (service, library, app):
        if not executable.is_file():
            raise RuntimeError("Run probe_monado_runtime.sh --build first")
    icd = Path("/usr/share/vulkan/icd.d/nvidia_icd.x86_64.json")
    if not icd.is_file():
        raise RuntimeError("NVIDIA ICD absent; no software fallback")
    runtime.chmod(0o700)
    for name in ("capture-failed", "capture-complete", "monado-stereo.h264", "monado-stereo.json", "monado-stereo.jsonl", "decoded.rgb",
                 "server-eye-left.ppm", "server-eye-right.ppm"):
        (out / name).unlink(missing_ok=True)
    manifest = out / "runtime.json"
    manifest.write_text(json.dumps({"file_format_version": "1.0.0", "runtime": {
        "name": "Meteor diagnostic Monado", "library_path": str(library)}}))
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), XR_RUNTIME_JSON=str(manifest),
               SIMULATED_ENABLE="1", XRT_COMPOSITOR_NULL="1", XRT_NO_STDIN="1",
               VK_ICD_FILENAMES=str(icd), VK_DRIVER_FILES=str(icd),
               METEOR_CONTINUOUS_FRAMES=str(frame_count),
               METEOR_XR_EYE_SIZE=str(eye_size), XRT_COMPOSITOR_NULL_FPS=str(target_hz),
               METEOR_XR_EYE_HEIGHT=str(eye_height), METEOR_XR_FOVEATED_ENCODING=foveated,
               METEOR_XR_BITRATE_MBPS=str(bitrate_mbps),
               METEOR_XR_CODEC=codec,
               METEOR_PROBE_OUTPUT=str(out), METEOR_NVENC_BRIDGE=str(out / "libmeteor-nvenc-probe.so"))
    # Preserve the actual host audio endpoints BEFORE replacing the runtime
    # directory for XR IPC. Do not change global defaults or the user's sink.
    env.update(host_audio_environment(os.environ))
    process_diagnostics=bool(external_spec and (root / ".build-cache/meteor-xr/process-diagnostics.enabled").is_file())
    env.pop("METEOR_XR_WAIT_DIAGNOSTICS",None)
    if process_diagnostics: env["METEOR_XR_WAIT_DIAGNOSTICS"]="1"
    env.pop("METEOR_XR_GPU_SCENE_SHADER", None)
    env.pop("METEOR_XR_ENGINE_FIXTURE",None)
    env.pop("METEOR_XR_MONITOR_LEGACY",None)
    if os.environ.get("NIGHTFALL_XR_MONITOR_LEGACY") == "1": env["METEOR_XR_MONITOR_LEGACY"]="1"
    engine_token=secrets.token_hex(16) if godot_engine and not external_spec else None
    env.pop("METEOR_ENGINE_RUN_ID",None)
    env.pop("METEOR_XR_RUNTIME_GENERATION",None)
    runtime_generation = os.environ.get("NIGHTFALL_XR_RUNTIME_GENERATION")
    if runtime_generation is not None:
        if not re.fullmatch(r"[0-9a-f]{32}", runtime_generation):
            raise ValueError("Invalid runtime event generation")
        env["METEOR_XR_RUNTIME_GENERATION"] = runtime_generation
    launch_intent=os.environ.get("NIGHTFALL_XR_LAUNCH_INTENT")
    env.pop("METEOR_XR_LAUNCH_INTENT",None)
    if launch_intent is not None:
        if not re.fullmatch(r"[0-9a-f]{32}",launch_intent): raise ValueError("Invalid launch intent generation")
        env["METEOR_XR_LAUNCH_INTENT"]=launch_intent
    if engine_token: env["METEOR_ENGINE_RUN_ID"]=engine_token
    (out / "engine-request-exit").unlink(missing_ok=True)
    if godot_engine and not external_spec: env["METEOR_XR_ENGINE_FIXTURE"]="1"
    env.pop("METEOR_XR_PADDED_SUBRECT",None)
    env.pop("METEOR_XR_SOURCE_FORMAT",None)
    source_format=os.environ.get("NIGHTFALL_XR_SOURCE_FORMAT","rgba8")
    if source_format not in ("rgba8","bgra8","rgba8-srgb","bgra8-srgb"):
        raise ValueError("Unsupported source format fixture")
    if source_format!="rgba8":
        if hello_xr or gpu_scene or (godot_engine and not external_spec): raise ValueError("Alternate source format requires reference renderer")
        env["METEOR_XR_SOURCE_FORMAT"]=source_format
    env.pop("METEOR_XR_ARRAY_STEREO",None)
    if os.environ.get("NIGHTFALL_XR_ARRAY_STEREO")=="1":
        if hello_xr or gpu_scene or godot_engine: raise ValueError("Array fixture requires reference renderer")
        env["METEOR_XR_ARRAY_STEREO"]="1"
    if os.environ.get("NIGHTFALL_XR_PADDED_SUBRECT")=="1":
        if hello_xr or gpu_scene or godot_engine: raise ValueError("Padded subrect fixture requires the reference renderer")
        env["METEOR_XR_PADDED_SUBRECT"]="1"
    env.pop("METEOR_XR_GPU_MEASURE", None)
    env.pop("METEOR_XR_HEADSET_OPTICS", None)
    env.pop("METEOR_XR_RASTER_SCENE", None)
    env.pop("METEOR_XR_HELLO_DIAGNOSTIC", None)
    env.pop("METEOR_XR_CONTROLLERS",None)
    env.pop("METEOR_XR_TOUCH_INPUTS",None)
    env.pop("METEOR_XR_INPUT_SECONDS",None)
    if input_seconds: env["METEOR_XR_INPUT_SECONDS"]=str(input_seconds)
    if touch_inputs: env["METEOR_XR_TOUCH_INPUTS"]="1"
    env.pop("METEOR_XR_HAPTICS",None)
    if os.environ.get("NIGHTFALL_XR_HAPTICS")=="1":
        if not touch_inputs: raise ValueError("Haptics require extended Touch inputs")
        env["METEOR_XR_HAPTICS"]="1"
    if controllers:
        env["METEOR_XR_CONTROLLERS"]="1"; env["SIMULATED_LEFT"]=controller_profile; env["SIMULATED_RIGHT"]=controller_profile
    if hello_xr:
        env["METEOR_XR_HELLO_DIAGNOSTIC"]="1"
    if raster_scene:
        for stage in ("vert","frag"):
            if not (build / f"meteor_raster_scene.{stage}.spv").is_file():
                raise RuntimeError("Rebuild runtime probe to compile raster shaders")
        env["METEOR_XR_RASTER_SCENE"]=str(build)
    if headset_optics:
        env["METEOR_XR_HEADSET_OPTICS"] = "1"
    if gpu_measure:
        env["METEOR_XR_GPU_MEASURE"] = "1"
    if gpu_scene:
        shader = build / "meteor_gpu_scene.spv"
        if not shader.is_file():
            raise RuntimeError("Rebuild runtime probe to compile GPU scene shader")
        env["METEOR_XR_GPU_SCENE_SHADER"] = str(shader)
    transport.start()
    env.update(transport.environment())
    env.pop("METEOR_XR_FREE_RUNNING", None)
    env.pop("METEOR_XR_ASYNC_DELIVERY", None)
    env.pop("METEOR_XR_ASYNC_ENCODE", None)
    if async_encode:
        env["METEOR_XR_ASYNC_ENCODE"] = "1"
    if async_delivery:
        env["METEOR_XR_ASYNC_DELIVERY"] = "1"
    if free_running:
        env["METEOR_XR_FREE_RUNNING"] = "1"
    tracking_port = os.environ.get("NIGHTFALL_XR_TRACKING_PORT")
    if tracking_port:
        if not tracking_port.isdecimal() or not 1 <= int(tracking_port) <= 65535:
            raise ValueError("Tracking port must be a valid loopback/ADB-forwarded port")
        env["METEOR_TRACKING_PORT"] = tracking_port
        env["METEOR_TRACKING_BRIDGE"] = str(out / "libmeteor-tracking-probe.so")
    device_port = os.environ.get("NIGHTFALL_XR_DEVICE_PORT")
    interrupted = forced_stop = False
    (out / "lifecycle-outcome.json").unlink(missing_ok=True)
    (out / "engine-outcome.json").unlink(missing_ok=True)
    (out / "client-disconnected").unlink(missing_ok=True)
    if device_port:
        if not device_port.isdecimal() or not 1 <= int(device_port) <= 65535 or os.environ.get("NIGHTFALL_XR_TRANSPORT_RECEIVER"):
            raise ValueError("Device port must be a valid ADB-forwarded port, with no local receiver configured")
        env["METEOR_XR_DIRECT_PORT"] = device_port
    application_env = env
    if external_spec:
        from xr_local_application import application_environment
        application_env = application_environment(external_spec, env)
    with managed_runtime([str(service)], env=env,
                         ready_path=runtime / "monado_comp_ipc",
                         log_path=out / "service.log", state_path=out / "runtime-state.json",
                         cancel_path=out / "client-disconnected") as child:
        # Application launch is fixture-owned, not part of service readiness.
        # Keep this scope until the application has been reaped on every path.
        owner_alive = None
        spec = json.loads(Path(external_spec).read_text()) if external_spec else {}
        if spec.get("launch") in ("manual","steam"):
            from xr_local_application import wait_for_local_launch
            request = wait_for_local_launch(out, env, cancelled=lambda: child.poll() is not None,
                                            steam_app_id=spec.get("steam_app_id") if spec.get("launch")=="steam" else None)
            if spec.get("launch")=="steam":
                command, external_cwd = request["argv"], request["cwd"]
                # Only validated Steam-specific keys are forwarded. Runtime/IPC
                # and compatibility selection remain owned by this supervisor.
                application_env = application_environment(external_spec,dict(env,**request["environment"]))
                def owner_alive():
                    try:
                        os.kill(request["owner_pid"],0)
                        return True
                    except OSError:
                        return False
        application_start = time.monotonic()
        if abort_test:
            application = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
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
            try:
                result, interrupted, forced_stop = run_application(command, env=application_env,
                    timeout=(300 if upstream_demo and frame_count > 3600 else 90 if upstream_demo and frame_count > 1800 else 40)+input_seconds, service_log=out / "service.log",
                    stop_file=out / "client-disconnected", watch_disconnect=bool((device_port or expect_tracking_loss) and (hello_xr or godot_engine)),
                    completion_file=out / "engine-completion.json" if godot_engine and not external_spec else None,
                    completion_token=engine_token,completion_target=frame_count,
                    cwd=external_cwd, terminate_on_stop=bool(external_spec), owner_alive=owner_alive,
                    output_path=out / "application-live.log" if external_spec else None,
                    diagnostics_path=out / "process-waits.jsonl" if process_diagnostics else None,
                    runtime_pid=child.pid, failure_file=out / "capture-failed")
            except subprocess.TimeoutExpired as failure:
                def output_text(value):
                    return value.decode(errors="replace") if isinstance(value,bytes) else (value or "")
                (out / "probe.log").write_text(output_text(failure.stdout)+output_text(failure.stderr))
                raise
        (out / "probe.log").write_text(result.stdout + result.stderr)
        if spec.get("launch")=="steam":
            outcome={"generation":env.get("METEOR_XR_RUNTIME_GENERATION"),"app_id":spec["steam_app_id"],
                     "returncode":result.returncode,"interrupted":interrupted,"forced":forced_stop}
            temporary=out / "steam-outcome.tmp"
            temporary.write_text(json.dumps(outcome))
            temporary.replace(out / "steam-outcome.json")
        application_elapsed = time.monotonic()-application_start
        if not abort_test and not interrupted:
            result.check_returncode()
            if not (hello_xr or godot_engine) and f"APP_SOURCE_FORMAT name={source_format} " not in result.stdout:
                raise RuntimeError("Requested source-format fixture did not execute")
            if os.environ.get("NIGHTFALL_XR_ARRAY_STEREO")=="1" and "APP_EYE_ARRAY shared=1 slices=1,0" not in result.stdout:
                raise RuntimeError("Array-stereo source fixture did not execute")
            if os.environ.get("NIGHTFALL_XR_PADDED_SUBRECT")=="1":
                for eye,x,y in ((0,8,12),(1,12,8)):
                    evidence=f"APP_EYE_SUBRECT eye={eye} source={eye_size+32}x{eye_size+32} offset={x},{y} extent={eye_size}x{eye_size}"
                    if evidence not in result.stdout:
                        raise RuntimeError("Padded subrect source fixture did not execute")
    # App and service have both been reaped by their owned scopes above. This
    # permits a bounded validation-only grace after a client finishes its stream.
    (out / "postrun-validation").write_text("app/service reaped\n")
    text = (out / "service.log").read_text()
    if not (hello_xr or godot_engine) and not interrupted:
        formats={"rgba8":37,"bgra8":44,"rgba8-srgb":43,"bgra8-srgb":50} # Stable VkFormat enum values.
        expected=formats[source_format]
        packed=43 if source_format.endswith("-srgb") else 37
        evidence=f"METEOR_SOURCE_FORMAT left={expected} right={expected} packed={packed} preserve_display_bytes=1"
        if evidence not in text:
            raise RuntimeError("Requested source/packed formats did not reach the encoder")
    if expect_tracking_loss and not interrupted:
        raise RuntimeError("Expected tracking interruption was not observed")
    if interrupted:
        records_path=out / "monado-stereo.jsonl"
        count=len(records_path.read_text().splitlines()) if records_path.exists() else 0
        if not count or "METEOR_TRACKING_READY" not in text:
            raise RuntimeError("Tracking disconnected before a live XR stream was established")
        outcome={"outcome":"interrupted", "reason":"tracking_transport_or_protocol_disconnected",
                 "encoded_frames":count,"app_exit_code":result.returncode,
                 "forced_app_termination":forced_stop,"final_drain_verified":False}
        (out / "lifecycle-outcome.json").write_text(json.dumps(outcome,indent=2)+"\n")
        print("INTERRUPTED: headset tracking connection ended; host sample stopped; not a completed stream/drain PASS",flush=True)
        if forced_stop: print("WARNING: graceful sample exit timed out; exact child was terminated",flush=True)
        return
    if tracking_port and ("METEOR_TRACKING_READY" not in text or
                          "METEOR_TRACKING_APPLIED" not in text or
                          "METEOR_TRACKING_FAILED" in text):
        raise RuntimeError("Live tracking did not reach the Monado virtual HMD")
    if "METEOR_ENCODE_OK" not in text or "METEOR_CAPTURE_FAILED" in text or "METEOR_DIRECT_FAILED" in text:
        raise RuntimeError("Encoder bridge did not acknowledge output")
    transport.finish()
    if external_spec:
        from xr_local_application import validate_capture
        count = validate_capture(out, text)
        (out / "external-application-outcome.json").write_text(json.dumps({
            "outcome": "completed", "encoded_frames": count,
            "app_exit_code": result.returncode, "final_drain_verified": True,
            "automatic_detection": False}, indent=2) + "\n")
        return
    if godot_engine:
        from check_xr_engine import validate_engine
        if upstream_demo and ("ENGINE_XR_UPSTREAM origin_centric_movement" not in result.stdout
                              or "OpenXR instantiated successfully." not in result.stdout):
            raise RuntimeError("Upstream application did not initialize its own XR scene")
        validate_engine(out,result.stdout+result.stderr,frame_count,eye_size,text)
        if upstream_demo:
            from prepare_xr_upstream_demo import PIN
            report_path=out / "engine-outcome.json"
            report=json.loads(report_path.read_text())
            report["application"]="godot-demo-projects/xr/openxr_origin_centric_movement"
            report["application_revision"]=PIN
            report["application_adaptations"]=["Mobile Vulkan renderer", "depth submission disabled",
                "diagnostic lifecycle autoload", "gravity call on CharacterBody3D"]
            report["controller_interaction_verified"]=False
            if controllers:
                from check_xr_upstream_input import inspect_input
                report["controller_input"]=inspect_input(result.stdout,
                    synthetic=not bool(device_port))
                report["controller_interaction_verified"]=not bool(device_port)
            report_path.write_text(json.dumps(report,indent=2)+"\n")
        return
    if not hello_xr:
        color=json.loads(subprocess.check_output(["ffprobe","-v","error","-select_streams","v:0",
            "-show_entries","stream=color_transfer","-of","json",str(out / "monado-stereo.h264")],text=True))
        expected_transfer="iec61966-2-1" if source_format.endswith("-srgb") else "bt709"
        if len(color.get("streams",[]))!=1 or color["streams"][0].get("color_transfer")!=expected_transfer:
            raise RuntimeError("Encoded transfer metadata does not match the selected source color policy")
    retains = text.count("METEOR_IMAGE_LEASE retain=1 ")
    releases = text.count("METEOR_IMAGE_LEASE retain=0 ")
    if not retains or retains != releases or "METEOR_IMAGE_LEASE_FAILED" in text:
        raise RuntimeError(f"Unbalanced image ownership: retains={retains} releases={releases}")
    if "METEOR_CAPTURE_EYE" in text or (out / "server-eye-left.ppm").exists():
        raise RuntimeError("CPU readback path unexpectedly ran")
    records = [json.loads(line) for line in (out / "monado-stereo.jsonl").read_text().splitlines()]
    expected_times = [int(value) for value in re.findall(r"Frame \d+ monotonic_ns=(\d+)", result.stdout)]
    if abort_test:
        if not 5 <= len(records) < frame_count or len(expected_times) < len(records):
            raise RuntimeError("Disconnect test did not interrupt an active sequence")
        frame_count = len(records)
        expected_times = expected_times[:frame_count]
    source_indices = list(range(frame_count))
    if free_running:
        if len(expected_times) != submitted_count:
            raise RuntimeError("App submission log incomplete")
        source_indices = match_submitted_frames(expected_times,
            [r["display_time_ns"] for r in records], allow_drops=True)
        frame_count = len(records)
        expected_times = [expected_times[i] for i in source_indices]
        print(f"Free-running accounting: submitted={submitted_count} encoded={frame_count} submission_skipped={submitted_count-frame_count}; final frame drained")
    if len(records) != frame_count or len(expected_times) != frame_count:
        raise RuntimeError("Missing or duplicated frames")
    offset, last_frame, last_time = 0, 0, 0
    for metadata, expected_time in zip(records, expected_times):
        if metadata["display_time_ns"] != expected_time or expected_time <= last_time:
            raise RuntimeError("Encoded display timestamps do not match submitted frame order")
        if metadata["frame_id"] <= last_frame or (metadata["width"], metadata["height"]) != (eye_size*2, eye_height):
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
    if async_delivery:
        drain = re.findall(r"METEOR_ASYNC_DRAIN delivered=(\d+) peak_pending=(\d+) failed=(\d+)", text)
        if len(drain)!=1 or int(drain[0][0])!=frame_count or not 1<=int(drain[0][1])<=2 or drain[0][2]!="0":
            raise RuntimeError("Asynchronous transport did not drain its bounded queue")
        print(f"Async delivery: {drain[0][0]} packets drained; peak pending={drain[0][1]} (capacity 2)")
    if async_encode:
        drain = re.findall(r"METEOR_RAW_DRAIN accepted=(\d+) encoded=(\d+) replaced=(\d+) failed=(\d+)", text)
        if len(drain)!=1 or int(drain[0][1])!=frame_count or int(drain[0][0])!=frame_count+int(drain[0][2]) or drain[0][3]!="0":
            raise RuntimeError("Raw encode queue ownership/accounting did not drain cleanly")
        print(f"Async encoding: accepted={drain[0][0]} encoded={drain[0][1]} pending_replaced={drain[0][2]}")
    subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                    "-i", str(out / "monado-stereo.h264"), "-pix_fmt", "rgb24", "-f", "rawvideo",
                    str(out / "decoded.rgb")], check=True, timeout=20)
    if hello_xr:
        decoded=(out / "decoded.rgb").read_bytes()
        if len(decoded)!=frame_count*eye_size*eye_size*6 or f"HELLO_XR_FINAL_DRAIN frames={submitted_count}" not in result.stdout:
            raise RuntimeError("Independent sample decode count/final drain evidence missing")
        first=decoded[:eye_size*eye_size*6]
        if max(first)-min(first)<40 or len(set(first[::3]))<16:
            raise RuntimeError("Independent sample output appears blank")
        print("PASS: independent hello_xr sample rendered nonblank video; no pixel oracle or general game compatibility claimed")
    elif gpu_measure:
        decoded = (out / "decoded.rgb").read_bytes()
        if len(decoded) != frame_count*eye_size*eye_size*6:
            raise RuntimeError("Measured scene decoded frame count mismatch")
        gpu_samples = re.findall(r"APP_GPU_EYE gpu_us=([0-9.]+) submit_wait_us=(\d+)",result.stdout)
        if len(gpu_samples) != submitted_count*2 or "APP_GPU_SCENE enabled=1 reference_validation=0" not in result.stdout:
            raise RuntimeError("Missing GPU measurement evidence")
        print("MEASUREMENT ONLY: decode count/accounting checked; no per-frame pixel oracle or image readback")
        if raster_scene:
            from check_xr_raster_scene import validate_raster_scene
            validate_raster_scene(decoded,eye_size,frame_count)
            if "APP_RASTER_SCENE enabled=1 cubes=25 depth_test=1" not in result.stdout:
                raise RuntimeError("Raster renderer initialization evidence missing")
            print("PASS: raster scene decoded foreground/background, stereo difference and animation smoke checks")
    elif tracked_scene:
        left = (out / "scene-left.rgb").read_bytes()
        right = (out / "scene-right.rgb").read_bytes()
        decoded = (out / "decoded.rgb").read_bytes()
        eye_bytes = eye_size*eye_size*3
        row_bytes = eye_size*3
        if len(left) != submitted_count*eye_bytes or len(right) != len(left) or len(decoded) != frame_count*eye_bytes*2:
            raise RuntimeError("Scene reference/decoded frame count mismatch")
        # Compare the real encoded/decode output with app-side pixel-verified
        # reference rows, not the old synthetic stripe validator.
        total_error = 0
        for frame in range(frame_count):
            for row in range(eye_size):
                start = source_indices[frame]*eye_bytes+row*row_bytes
                reference = left[start:start+row_bytes]+right[start:start+row_bytes]
                offset = frame*eye_bytes*2+row*row_bytes*2
                total_error += sum(abs(a-b) for a,b in zip(reference,decoded[offset:offset+row_bytes*2]))
        error = total_error/len(decoded)
        if error > 12:
            raise RuntimeError(f"Decoded pose scene differs from app reference: mean byte error {error:.3f}")
        print(f"Scene encode/decode reference mean byte error: {error:.3f}")
    else:
        validate((out / "decoded.rgb").read_bytes(), frames=frame_count, greens=[(i * 73) % 256 for i in source_indices], eye_size=eye_size)
    def summary(pattern, source):
        values = sorted(int(value) for value in re.findall(pattern, source))
        if not values:
            return None
        return {"samples": len(values), "p50_us": statistics.median(values),
                "p95_us": values[min(len(values)-1, int(len(values)*.95))], "max_us": max(values)}
    timings = {"eye_size": eye_size, "eye_height":eye_height, "target_hz": target_hz, "submitted": submitted_count,
               "source_format": source_format if not hello_xr else "sample-selected",
               "array_stereo_fixture": os.environ.get("NIGHTFALL_XR_ARRAY_STEREO")=="1",
               "padded_subrect_fixture": os.environ.get("NIGHTFALL_XR_PADDED_SUBRECT")=="1",
               "gpu_scene": gpu_scene, "measurement_only": gpu_measure,
               "headset_optics": headset_optics,
               "raster_scene": raster_scene,
               "hello_xr": hello_xr,
               "controllers": controllers,
               "controller_profile": controller_profile if controllers else None,
               "touch_inputs": touch_inputs,
               "pixel_reference_validated": not (gpu_measure or hello_xr),
               "encoded": frame_count, "application_elapsed_s": application_elapsed,
               "display_timestamp_cadence_hz": (frame_count-1)*1e9/(records[-1]["display_time_ns"]-records[0]["display_time_ns"]) if frame_count>1 else None,
               "app_reference_frame": summary(r"APP_RENDER frame=\d+ us=(\d+)",result.stdout),
               "app_eye_acquire_wait": summary(r"APP_EYE wait_us=(\d+)",result.stdout),
               "app_eye_generate": summary(r"APP_EYE wait_us=\d+ generate_us=(\d+)",result.stdout),
               "app_eye_submit_readback": summary(r"submit_readback_us=(\d+)",result.stdout),
               "app_eye_verify_artifact": summary(r"verify_artifact_us=(\d+)",result.stdout),
               "app_eye_release": summary(r"release_us=(\d+)",result.stdout),
               "pack_record_submit_wait": summary(r"GPU_PACK frame=\d+ us=(\d+)",text),
               "nvenc_submit_to_packet_copy": summary(r"submit-to-lock-us=(\d+)",text)}
    if gpu_measure:
        values=sorted(float(sample[0]) for sample in gpu_samples)
        gpu_stage="app_eye_gpu_raster" if raster_scene else "app_eye_gpu_dispatch_copy"
        timings[gpu_stage]={"samples":len(values),"p50_us":statistics.median(values),
            "p95_us":values[min(len(values)-1,int(len(values)*.95))],"max_us":max(values)}
        timings["app_eye_submit_fence_wait"]=summary(r"APP_GPU_EYE gpu_us=[0-9.]+ submit_wait_us=(\d+)",result.stdout)
    (out / "timing-summary.json").write_text(json.dumps(timings,indent=2)+"\n")
    print(f"Profile: {eye_size}x{eye_height} per eye, target {target_hz} Hz; timing-summary.json records CPU-wall stages (not motion-to-photon)")
    label = "unexpected app disconnect" if abort_test else "normal session exit"
    evidence = "decode count, timestamps and bitstream accounting checked; pixel oracle disabled" if (gpu_measure or hello_xr) else "decoded pixels, timestamps and bitstream ranges match"
    print(f"PASS: {frame_count} Monado frames; one persistent encoder/surface; {evidence}; clean drain after {label}")
    print(f"Artifacts: {out}")


if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
