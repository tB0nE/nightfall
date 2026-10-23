"""Real Monado/Vulkan/NVENC overlay-only transition regression; no headset."""
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import socket
import re
import argparse
import numpy as np


def rotate(q, v):
    xyz=np.array(q[:3]); v=np.array(v)
    t=2*np.cross(xyz,v)
    return v+q[3]*t+np.cross(xyz,t)


def run(root, eye_size=256, hz=60, codec="h264", bitrate=32):
    cache=root / ".build-cache/meteor-xr"
    out=Path(tempfile.mkdtemp(prefix="quad-smoke-",dir=cache))
    print(f"Quad smoke diagnostics: {out}",flush=True)
    receiver=out / "receiver"
    subprocess.run(["rustc","--edition=2024","-O",str(root / "meteor/tools/xr_transport_receiver.rs"),"-o",str(receiver)],check=True)
    endpoint=out / "publisher"
    subprocess.run(["c++","-std=c++17","-O2","-pthread","-I"+str(root / "extensions/nightfall-xr/include"),
        str(root / "test/pcvr_meteor_tracking_endpoint_test.cpp"),
        str(root / "extensions/nightfall-xr/src/pcvr_meteor_tracking_endpoint.cpp"),"-o",str(endpoint)],check=True)
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1",0)); port=reserve.getsockname()[1]
    spec=out / "application.json"
    spec.write_text(json.dumps({"argv":[str(cache / "monado-linux-spike/runtime-probe")],"cwd":str(root)}))
    env={k:v for k,v in os.environ.items() if not k.startswith(("NIGHTFALL_XR_","METEOR_XR_"))}
    env.update(NIGHTFALL_XR_APPLICATION_SPEC=str(spec),NIGHTFALL_XR_GODOT_ENGINE="1",
        NIGHTFALL_XR_UPSTREAM_DEMO="1",METEOR_XR_TRACKED_SCENE="1",METEOR_XR_QUAD_FIXTURE="1",
        NIGHTFALL_XR_EYE_SIZE=str(eye_size),NIGHTFALL_XR_TARGET_HZ=str(hz),NIGHTFALL_XR_PROBE_FRAMES="24",
        NIGHTFALL_XR_CODEC=codec,
        NIGHTFALL_XR_BITRATE_MBPS=str(bitrate),
        NIGHTFALL_XR_FREE_RUNNING="1",NIGHTFALL_XR_ASYNC_ENCODE="1",NIGHTFALL_XR_ASYNC_DELIVERY="1",
        NIGHTFALL_XR_TRANSPORT_RECEIVER=str(receiver),NIGHTFALL_XR_PROBE_OUTPUT=str(out))
    env["NIGHTFALL_XR_TRACKING_PORT"]=str(port)
    publisher=subprocess.Popen([str(endpoint),str(port),"moving"],stdout=subprocess.PIPE,text=True)
    try:
        assert publisher.stdout.readline().strip()=="READY synthetic tracking publisher"
        with (out / "smoke.log").open("w") as log:
            subprocess.run(["bash",str(root / "tools/build_support/probe_monado_nvenc.sh")],
                env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
    finally:
        publisher.terminate(); publisher.communicate(timeout=3)
    records=[json.loads(line) for line in (out / "monado-stereo.jsonl").read_text().splitlines()]
    service=(out / "service.log").read_text()
    assert f"METEOR_VIDEO_CONFIG eye_size={eye_size} bitrate_bps={bitrate*1000000}" in service
    assert f"METEOR_VIDEO_CODEC codec={codec} fps={hz}" in service
    assert "METEOR_COMPOSITION projection=0 quads=8 gpu=1" in service
    assert "METEOR_COMPOSITION projection=1 quads=8 gpu=1" in service
    assert "METEOR_CAPTURE_FAILED" not in service and "METEOR_IMAGE_LEASE_FAILED" not in service
    hold=re.search(r"APP_QUAD_STATIC_HOLD source_ns=(\d+) ms=650",(out / "application-live.log").read_text())
    assert hold,"Static loading hold did not run"
    held_source=int(hold[1])
    held_frames=[r for r in records if not r["projection"] and held_source+400000000<r["display_time_ns"]<held_source+650000000]
    assert held_frames,"Static overlays did not keep rendering beyond the 250ms tracking-history limit"
    # Decode the actual delivered encoder output, not an app-side render.
    video=out / "monado-stereo.h264" # Historical diagnostic basename; inspect actual bitstream.
    info=json.loads(subprocess.check_output(["ffprobe","-v","error","-show_streams","-of","json",str(video)]))["streams"][0]
    assert (info["width"],info["height"]) == (eye_size*2,eye_size)
    assert info["codec_name"] == ("hevc" if codec=="h265" else "h264")
    # Bound oracle memory at higher resolutions; decode actual full-resolution
    # stream first, then scale for the same normalized-coordinate pixel checks.
    raw=subprocess.check_output(["ffmpeg","-v","error","-i",str(video),
        "-vf","scale=512:256","-f","rawvideo","-pix_fmt","rgb24","-threads","1","pipe:1"])
    frames=np.frombuffer(raw,dtype=np.uint8).reshape(-1,256,512,3)
    assert len(frames)==len(records)
    samples=[]
    transitions=[]
    for frame_index,(frame,record) in enumerate(zip(frames,records)):
        projection=record["projection"]
        if not transitions or transitions[-1]!=projection: transitions.append(projection)
        head=(np.array(record["views"][0]["position"])+record["views"][1]["position"])*.5
        for eye,view in enumerate(record["views"]):
            q=view["orientation"]; inv=[-q[0],-q[1],-q[2],q[3]]
            offset=rotate(inv,np.array(view["position"])-head)
            left,right,up,down=map(math.tan,view["fov"])
            for i in range(8):
                p=np.array([(i%3-1)*.8,.6-(i//3)*.6,-2])-offset
                nx=(2*p[0]+(right+left)*p[2])/(right-left)/-p[2]
                ny=(-2*p[1]-(up+down)*p[2])/(up-down)/-p[2]
                x=int((nx+1)*128)+eye*256; y=int((ny+1)*128)
                rgb=frame[y-1:y+2,x-1:x+2].mean(axis=(0,1))
                visible=not ((i==0 and eye==1) or (i==1 and eye==0))
                background=64 if projection else 0
                expected_green=128+background*.5 if visible else background
                assert abs(rgb[1]-expected_green)<18,(frame_index,eye,i,rgb,expected_green)
                samples.append({"frame":frame_index,"projection":projection,"eye":eye,"quad":i,"visible":visible,"rgb":rgb.tolist()})
    assert transitions==[0,1,0,1],transitions
    report={"outcome":"passed","encoded_frames":len(frames),"quad_count":8,"transitions":transitions,"static_hold_ms":650,"late_held_frames":len(held_frames),"samples":samples}
    (out / "quad-outcome.json").write_text(json.dumps(report,indent=2)+"\n")
    print("PASS: eight quads, 650ms static loading hold, overlay/projection transitions, stereo visibility, alpha and image/encoder drain",flush=True)


if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("root",type=Path)
    parser.add_argument("--eye-size",type=int,choices=(256,512,1024,2048,2560),default=256)
    parser.add_argument("--hz",type=int,choices=(20,60,72),default=60)
    parser.add_argument("--codec",choices=("h264","h265"),default="h264")
    parser.add_argument("--bitrate",type=int,default=32)
    args=parser.parse_args()
    run(args.root.resolve(),args.eye_size,args.hz,args.codec,args.bitrate)
