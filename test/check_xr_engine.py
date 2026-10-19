"""Engine smoke evidence, deliberately not an app pixel/timestamp oracle."""
import json
import math
import re
import subprocess


def validate_engine(out, application_log, minimum, eye_size, service_log):
    if "ENGINE_XR_READY renderer=mobile" not in application_log or "ENGINE_XR_COMPLETE" not in application_log:
        raise RuntimeError("Godot did not initialize/render/complete its own OpenXR session")
    if "SCRIPT ERROR" in application_log or "ENGINE_XR_FAILED" in application_log or "XR_ERROR_" in application_log:
        raise RuntimeError("Engine scene reported an error")
    if "ENGINE_XR_STOPPING" not in application_log or "METEOR_ENGINE_EXIT_REQUESTED" not in service_log:
        raise RuntimeError("Engine did not exit through runtime session stopping")
    warnings=[]
    for line in application_log.splitlines():
        if not line.startswith("ERROR:"): continue
        if ("OpenXRAPI18InteractionProfileE" in line and "leaked at exit" in line) or (
            "Attempt to disconnect a nonexistent connection" in line and "OpenXRSpatialEntityExtension" in line):
            warnings.append(line)
        else:
            raise RuntimeError(f"Unexpected engine error: {line}")
    records=[json.loads(line) for line in (out / "monado-stereo.jsonl").read_text().splitlines()]
    if not minimum<=len(records)<=240:
        raise RuntimeError("Engine output frame count outside bounded diagnostic window")
    last_time=last_frame=offset=0
    for record in records:
        if record["display_time_ns"]<=last_time or record["frame_id"]<=last_frame or record["offset"]!=offset or record["bytes"]<=0:
            raise RuntimeError("Engine encoded metadata is unordered/noncontiguous")
        if (record["width"],record["height"])!=(eye_size*2,eye_size) or len(record["views"])!=2:
            raise RuntimeError("Engine stereo shape mismatch")
        for view in record["views"]:
            if not all(math.isfinite(v) for key in ("position","orientation","fov") for v in view[key]):
                raise RuntimeError("Invalid engine pose/FOV")
            if abs(sum(v*v for v in view["orientation"])-1)>.001:
                raise RuntimeError("Invalid engine orientation")
            left,right,up,down=view["fov"]
            if not left<right or not down<up: raise RuntimeError("Invalid engine FOV order")
        last_time,last_frame=record["display_time_ns"],record["frame_id"]
        offset+=record["bytes"]
    if offset!=(out / "monado-stereo.h264").stat().st_size:
        raise RuntimeError("Unaccounted engine bitstream bytes")
    retained=service_log.count("METEOR_IMAGE_LEASE retain=1 ")
    if not retained or retained!=service_log.count("METEOR_IMAGE_LEASE retain=0 "):
        raise RuntimeError("Engine image leases not balanced")
    if any(marker in service_log for marker in ("METEOR_CAPTURE_FAILED","METEOR_DIRECT_FAILED","METEOR_IMAGE_LEASE_FAILED")):
        raise RuntimeError("Engine GPU/transport ownership failure")
    if service_log.count("METEOR_ENCODER_INIT")!=1 or service_log.count("METEOR_ENCODER_RELEASED")!=1 or f"METEOR_ENCODER_DRAIN frames={len(records)} " not in service_log:
        raise RuntimeError("Engine encoder did not drain and release once")
    raw=re.findall(r"METEOR_RAW_DRAIN accepted=(\d+) encoded=(\d+) replaced=(\d+) failed=(\d+)",service_log)
    if raw and (len(raw)!=1 or int(raw[0][1])!=len(records) or int(raw[0][0])!=int(raw[0][1])+int(raw[0][2]) or raw[0][3]!="0"):
        raise RuntimeError("Engine raw worker accounting failed")
    delivery=re.findall(r"METEOR_ASYNC_DRAIN delivered=(\d+) peak_pending=(\d+) failed=(\d+)",service_log)
    if delivery and (len(delivery)!=1 or int(delivery[0][0])!=len(records) or not 1<=int(delivery[0][1])<=2 or delivery[0][2]!="0"):
        raise RuntimeError("Engine async delivery accounting failed")
    subprocess.run(["ffmpeg","-nostdin","-v","error","-y","-i",str(out / "monado-stereo.h264"),
        "-pix_fmt","rgb24","-f","rawvideo",str(out / "decoded.rgb")],check=True,timeout=20)
    decoded=(out / "decoded.rgb").read_bytes()
    frame_bytes=eye_size*eye_size*6
    if len(decoded)!=len(records)*frame_bytes or max(decoded[:frame_bytes])-min(decoded[:frame_bytes])<40:
        raise RuntimeError("Engine decoded output blank or incomplete")
    stereo=decoded[:frame_bytes]
    row_bytes=eye_size*6
    if not any(stereo[row*row_bytes:row*row_bytes+eye_size*3]!=stereo[row*row_bytes+eye_size*3:(row+1)*row_bytes] for row in range(eye_size)):
        raise RuntimeError("Engine stereo images are identical")
    formats=re.findall(r"METEOR_SOURCE_FORMAT left=(\d+) right=(\d+) packed=(\d+)",service_log)
    if not formats: raise RuntimeError("Engine source format evidence missing")
    if any(int(value) not in (43,50) for value in formats[0][:2]) or int(formats[0][2])!=43:
        raise RuntimeError("Godot did not select the expected SDR sRGB path")
    if "METEOR_STEREO_SOURCE shared_image=1" not in service_log or any(
        f"METEOR_EYE_SOURCE eye={eye} array_layers=2 slice={eye}" not in service_log for eye in (0,1)):
        raise RuntimeError("Engine did not exercise a shared two-slice swapchain")
    report={"engine":"Godot 4.7","encoded_frames":len(records),"eye_size":eye_size,
        "source_formats":list(map(int,formats[0])),"pixel_oracle":False,"app_submission_timestamp_oracle":False,
        "encoder_drain_verified":True,"image_leases_balanced":True,
        "shutdown_diagnostics":warnings,"engine_shutdown_clean":not warnings}
    (out / "engine-outcome.json").write_text(json.dumps(report,indent=2)+"\n")
    print(f"PASS: Godot OpenXR engine rendered {len(records)} decoded stereo frames; ordered metadata, balanced leases and encoder drain; smoke test, not pixel oracle")
    if warnings: print(f"WARNING: {len(warnings)} Godot shutdown diagnostics remain; not a clean engine-lifecycle pass")
