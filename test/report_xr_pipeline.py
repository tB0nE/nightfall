"""Host-clock XR stage report. ACK is codec input admission, NOT presentation."""
import argparse
import json
import math
from pathlib import Path
import re
import statistics


def summary(values):
    if not values:
        return None
    values=sorted(values)
    return {"samples":len(values), "p50_us":statistics.median(values),
            "p95_us":values[max(0,math.ceil(.95*len(values))-1)], "max_us":values[-1]}


def report(directory, target_hz=60, service_log=None):
    if target_hz not in (20,60):
        raise ValueError("Only bounded 20/60-Hz profiles are supported")
    text=(directory / "service.log").read_text() if service_log is None else service_log
    records=[json.loads(line) for line in (directory / "monado-stereo.jsonl").read_text().splitlines()]
    timestamps=[r["display_time_ns"] for r in records]
    gaps=[(b-a)/1000 for a,b in zip(timestamps,timestamps[1:])]
    if any(gap<=0 for gap in gaps):
        raise ValueError("Unordered encoded display timestamps")
    app=(directory / "probe.log").read_text() if (directory / "probe.log").exists() else ""
    monitor=re.search(r"ENGINE_MONITOR_TIMING mode=(\w+) polls=(\d+) bytes=(\d+) total_us=(\d+) max_us=(\d+) draws=(\d+) draw_span_us=(\d+) draw_max_us=(\d+)",app)
    monitor_report=None
    if monitor:
        mode,*values=monitor.groups()
        monitor_report=dict(zip(["polls","bytes_read","total_us","max_us","draw_callbacks","draw_span_us","draw_max_us"],map(int,values)))
        monitor_report["mode"]=mode
    patterns={
        "gpu_pack_wall":r"GPU_PACK frame=\d+ us=(\d+)",
        "nvenc_submit_to_lock":r"NVENC timestamp=\d+ bytes=\d+ submit-to-lock-us=(\d+)",
        "raw_queue_wait":r"METEOR_RAW_TIMING frame=\d+ queue_us=(\d+)",
        "encode_worker_wall":r"METEOR_RAW_TIMING frame=\d+ queue_us=\d+ encode_us=(\d+) ok=1",
        "delivery_queue_wait":r"METEOR_DELIVERY_TIMING frame=\d+ queue_us=(\d+)",
        "delivery_service":r"METEOR_DELIVERY_TIMING frame=\d+ queue_us=\d+ service_us=(\d+) ok=1",
        "local_socket_send":r"METEOR_DIRECT_TIMING frame=\d+ send_us=(\d+)",
        "codec_input_ack_roundtrip":r"METEOR_DIRECT_TIMING frame=\d+ send_us=\d+ ack_us=(\d+)",
    }
    return {"schema":1, "target_hz":target_hz, "encoded_frames":len(records),
        "packed_width":records[0].get("width") if records else None,
        "packed_height":records[0].get("height") if records else None,
        "application_diagnostic_monitor":monitor_report,
        "encoded_display_timestamp_hz":1e6/statistics.mean(gaps) if gaps else None,
        "encoded_display_interval":summary(gaps),
        "intervals_over_1_5_target_period":sum(gap>1.5e6/target_hz for gap in gaps),
        "stages":{name:summary([int(v) for v in re.findall(pattern,text)]) for name,pattern in patterns.items()},
        "delivery_backpressure_events":text.count("METEOR_DELIVERY_BACKPRESSURE waiting_for_slot=1"),
        "notes":["Host monotonic durations; encoded display timestamps are not headset presentation times.",
            "ACK confirms codec input admission, not decode completion or display.",
            "Stages overlap and nest; percentiles must not be added into end-to-end latency.",
            "No motion-to-photon measurement. Missing stages are null, not zero."]}


if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session",type=Path)
    parser.add_argument("--target-hz",type=int,choices=(20,60),default=60)
    args=parser.parse_args()
    print(json.dumps(report(args.session,args.target_hz),indent=2))
