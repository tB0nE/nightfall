"""Host-local opt-in application selection; never accepts a remote command.

This is a bounded Linux DEV launcher, not discovery or SteamVR/OpenVR support.
The inherited environment already selects the private managed OpenXR runtime.
"""
import json
import os
from pathlib import Path


def load_application(path):
    path = Path(path)
    if path.stat().st_size > 16384:
        raise ValueError("XR application configuration exceeds 16 KiB")
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or set(value) != {"argv", "cwd"}:
        raise ValueError("XR application requires exactly argv and cwd")
    argv, cwd = value["argv"], value["cwd"]
    if not isinstance(argv, list) or not 1 <= len(argv) <= 64:
        raise ValueError("XR application argv must contain 1..64 strings")
    if any(not isinstance(arg, str) or "\0" in arg or len(arg) > 4096 for arg in argv):
        raise ValueError("Invalid XR application argument")
    executable = Path(argv[0])
    if not executable.is_absolute() or not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("XR application executable must be an absolute executable file")
    if not isinstance(cwd, str) or "\0" in cwd or not Path(cwd).is_absolute() or not Path(cwd).is_dir():
        raise ValueError("XR application cwd must be an existing absolute directory")
    return argv, cwd


def validate_capture(output, service_log):
    """Validate capture ownership/drain without requiring demo-only stdout."""
    records = [json.loads(line) for line in (output / "monado-stereo.jsonl").read_text().splitlines()]
    if not records:
        raise RuntimeError("External application produced no encoded XR frames")
    offset = previous_id = previous_time = 0
    for record in records:
        if (record["offset"] != offset or record["bytes"] <= 0
                or record["frame_id"] <= previous_id or record["display_time_ns"] <= previous_time):
            raise RuntimeError("Invalid external application frame accounting")
        offset += record["bytes"]
        previous_id, previous_time = record["frame_id"], record["display_time_ns"]
    if offset != (output / "monado-stereo.h264").stat().st_size:
        raise RuntimeError("Unaccounted external application bitstream bytes")
    retained = service_log.count("METEOR_IMAGE_LEASE retain=1 ")
    if (not retained or retained != service_log.count("METEOR_IMAGE_LEASE retain=0 ")
            or "METEOR_IMAGE_LEASE_FAILED" in service_log
            or f"METEOR_ENCODER_DRAIN frames={len(records)} " not in service_log
            or service_log.count("METEOR_ENCODER_RELEASED") != 1):
        raise RuntimeError("External application image leases/encoder did not drain")
    return len(records)
