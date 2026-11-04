#!/usr/bin/env python3
"""Summarize a Windows GPU scene trial without treating decode as presentation."""
import argparse
import json
import re
import statistics
from pathlib import Path


def summarize(runtime, timeline):
    text = runtime.read_text(errors="replace")
    rows = [json.loads(line) for line in timeline.read_text(encoding="utf-8-sig").splitlines() if line.strip()]
    final = rows[-1][3]
    source = [(int(n), int(ns)) for n, ns in re.findall(r"Frame (\d+) monotonic_ns=(\d+)", text)]
    duration = (source[-1][1] - source[0][1]) / 1e9 if len(source) > 1 else 0
    timings = {}
    for name, pattern in {
        "gpu_eye_us": r"APP_GPU_EYE gpu_us=([\d.]+)",
        "app_render_us": r"APP_RENDER frame=\d+ us=(\d+)",
        "gpu_pack_us": r"GPU_PACK frame=\d+ us=(\d+)",
        "nvenc_submit_lock_us": r"submit-to-lock-us=(\d+)",
        "delivery_ack_us": r"METEOR_DIRECT_TIMING frame=\d+ send_us=\d+ ack_us=(\d+)",
    }.items():
        values = sorted(float(v) for v in re.findall(pattern, text))
        if values:
            timings[name] = {"samples": len(values), "median": statistics.median(values),
                             "p95": values[int((len(values) - 1) * .95)], "max": values[-1]}
    counts = final.get("meteor_device_counts", {})
    received = counts.get("received", 0)
    projected = counts.get("projection_copies", 0)
    ended = runtime.with_name("session-active.ended").is_file()
    changes = []
    previous = 0
    for row in rows:
        if len(row) < 6:
            continue
        count = row[3].get("meteor_device_counts", {}).get("received", 0)
        if count > previous and row[3].get("meteor_endpoints_ready"):
            changes.append((row[5]["elapsed_s"], count,
                            row[3]["meteor_device_counts"].get("projection_copies", 0)))
        previous = count
    observed = None
    if len(changes) > 1 and changes[-1][0] > changes[0][0]:
        first, last = changes[0], changes[-1]
        seconds = last[0] - first[0]
        observed = {"interval_s": seconds, "received_per_second": (last[1]-first[1])/seconds,
                    "projected_per_second": (last[2]-first[2])/seconds}
    return {
        "transport_ok": rows[-1][0] == "idle" and not final.get("error") and ended and received > 0,
        "source_interval_s": duration,
        "last_source_frame": max((n for n, _ in source), default=-1),
        "received": received, "decoded": counts.get("codec_outputs", 0), "projected": projected,
        "superseded_before_selection": counts.get("superseded_before_selection", 0),
        "received_per_source_second": received / duration if duration else None,
        "projected_per_source_second": projected / duration if duration else None,
        "decoder_error": final.get("error"), "acknowledged_end": ended,
        "observed_delivery": observed,
        "timings": timings,
        "input_states": sorted(set(re.findall(r"APP_INPUT [^\r\n]+", text))),
        "runtime_log": str(runtime), "timeline": str(timeline),
        "notes": ["Rates include startup effects and are approximate; the source targets 72 Hz.",
                  "An inactive controller action does not validate physical input.",
                  "Shared process logs can interleave lines; parsed timing sample counts may be incomplete.",
                  "Transport success does not imply smooth presentation or game compatibility."],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime_log", type=Path)
    parser.add_argument("timeline", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = summarize(args.runtime_log, args.timeline)
    data = json.dumps(result, indent=2)
    if args.output:
        args.output.write_text(data + "\n")
    print(data)
