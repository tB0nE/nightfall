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
import threading
import time
import numpy as np


def rotate(q, v):
    xyz=np.array(q[:3]); v=np.array(v)
    t=2*np.cross(xyz,v)
    return v+q[3]*t+np.cross(xyz,t)


def run(root, eye_size=256, hz=60, codec="h264", bitrate=32, live_bitrate=False, eye_height=None, foveated=False, live_foveation=False, panorama=False, layer_matrix=False, cylinder=False, cylinder_radius=2.0, stack=False, source_format="rgba8"):
    eye_height=eye_size if eye_height is None else eye_height
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
        NIGHTFALL_XR_EYE_HEIGHT=str(eye_height),NIGHTFALL_XR_FOVEATED_ENCODING="1" if foveated else "0",
        NIGHTFALL_XR_CODEC=codec,
        NIGHTFALL_XR_SOURCE_FORMAT=source_format,
        NIGHTFALL_XR_BITRATE_MBPS=str(bitrate),
        NIGHTFALL_XR_FREE_RUNNING="1",NIGHTFALL_XR_ASYNC_ENCODE="1",NIGHTFALL_XR_ASYNC_DELIVERY="1",
        NIGHTFALL_XR_TRANSPORT_RECEIVER=str(receiver),NIGHTFALL_XR_PROBE_OUTPUT=str(out))
    if panorama: env["METEOR_XR_PANORAMA_FIXTURE"]="1"
    if layer_matrix: env["METEOR_XR_LAYER_MATRIX"]="1"
    if cylinder:
        env["METEOR_XR_CYLINDER_FIXTURE"]="1"
        env["METEOR_XR_CYLINDER_RADIUS"]=str(cylinder_radius)
    if stack:
        env["METEOR_XR_STACK_FIXTURE"]="1"
        env["NIGHTFALL_XR_PROBE_FRAMES"]="40"
    env["NIGHTFALL_XR_TRACKING_PORT"]=str(port)
    publisher=subprocess.Popen([str(endpoint),str(port),"moving"],stdout=subprocess.PIPE,text=True)
    updates=[]
    stop_updates=threading.Event()
    def change_bitrate():
        for sequence,mbps in enumerate((40,24),1):
            deadline=time.monotonic()+75
            while not stop_updates.is_set() and time.monotonic()<deadline:
                if (out / "monado-stereo.jsonl").exists(): break
                time.sleep(.01)
            if stop_updates.is_set(): return
            temporary=out / "bitrate-request.tmp"
            temporary.write_text(f"{sequence} {mbps}\n")
            temporary.replace(out / "bitrate-request")
            while not stop_updates.is_set() and time.monotonic()<deadline:
                try:
                    ack=(out / "bitrate-ack").read_text().split()
                    if ack==[str(sequence),str(mbps),str(mbps*1000000),"0"]:
                        updates.append(mbps)
                        break
                except FileNotFoundError: pass
                time.sleep(.005)
    foveation_updates=[]
    def change_foveation():
        deadline=time.monotonic()+75
        for sequence,value in enumerate((1,0,1,0),1):
            while not stop_updates.is_set() and time.monotonic()<deadline:
                if (out / "monado-stereo.jsonl").exists(): break
                time.sleep(.01)
            if stop_updates.is_set(): return
            temporary=out / "foveation-request.tmp"
            temporary.write_text(f"{sequence} {value}\n")
            temporary.replace(out / "foveation-request")
            while not stop_updates.is_set() and time.monotonic()<deadline:
                try:
                    if (out / "foveation-ack").read_text().split()==[str(sequence),str(value),str(value),"0"]:
                        foveation_updates.append(value)
                        break
                except FileNotFoundError: pass
                time.sleep(.005)
    foveation_updater=threading.Thread(target=change_foveation)
    updater=threading.Thread(target=change_bitrate)
    try:
        assert publisher.stdout.readline().strip()=="READY synthetic tracking publisher"
        if live_bitrate: updater.start()
        if live_foveation: foveation_updater.start()
        with (out / "smoke.log").open("w") as log:
            subprocess.run(["bash",str(root / "tools/build_support/probe_monado_nvenc.sh")],
                env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
    finally:
        stop_updates.set()
        if live_bitrate: updater.join(timeout=2)
        if live_foveation: foveation_updater.join(timeout=2)
        publisher.terminate(); publisher.communicate(timeout=3)
    if live_bitrate: assert updates==[40,24],updates
    if live_foveation: assert foveation_updates==[1,0,1,0],foveation_updates
    records=[json.loads(line) for line in (out / "monado-stereo.jsonl").read_text().splitlines()]
    service=(out / "service.log").read_text()
    assert f"METEOR_VIDEO_CONFIG eye_size={eye_size} bitrate_bps={bitrate*1000000}" in service
    assert f"METEOR_VIDEO_CODEC codec={codec} fps={hz}" in service
    assert f"METEOR_FOVEATED_ENCODING enabled={int(foveated)} mode=qp_delta" in service
    if not stack: assert f"METEOR_COMPOSITION projection=0 quads={1 if panorama or cylinder else 8} gpu=1" in service
    if not stack: assert f"METEOR_COMPOSITION projection=1 quads={1 if cylinder else 8} gpu=1" in service
    assert "METEOR_CAPTURE_FAILED" not in service and "METEOR_IMAGE_LEASE_FAILED" not in service
    if layer_matrix:
        application=(out / "application-live.log").read_text()
        assert "APP_LAYER_MATRIX capabilities=verified" in application
        for reason in ("invalid_view_count","unsupported_type","invalid_source_rect","invalid_cylinder","cube","equirect1","null_layer"):
            assert f"APP_LAYER_MATRIX rejected={reason} expected_error=1" in application
        assert "APP_LAYER_MATRIX empty_frame=accepted" in application
        assert not (out / "capture-failed").exists()
    hold=re.search(r"APP_QUAD_STATIC_HOLD source_ns=(\d+) ms=650",(out / "application-live.log").read_text())
    assert hold,"Static loading hold did not run"
    held_source=int(hold[1])
    held_frames=[r for r in records if not r["projection"] and held_source+400000000<r["display_time_ns"]<held_source+650000000]
    assert held_frames,"Static overlays did not keep rendering beyond the 250ms tracking-history limit"
    # Decode the actual delivered encoder output, not an app-side render.
    video=out / "monado-stereo.h264" # Historical diagnostic basename; inspect actual bitstream.
    info=json.loads(subprocess.check_output(["ffprobe","-v","error","-show_streams","-of","json",str(video)]))["streams"][0]
    assert (info["width"],info["height"]) == (eye_size*2,eye_height)
    assert info["codec_name"] == ("hevc" if codec=="h265" else "h264")
    # Bound oracle memory at higher resolutions; decode actual full-resolution
    # stream first, then scale for the same normalized-coordinate pixel checks.
    raw=subprocess.check_output(["ffmpeg","-v","error","-i",str(video),
        "-vf","scale=512:256","-f","rawvideo","-pix_fmt","rgb24","-threads","1","pipe:1"])
    frames=np.frombuffer(raw,dtype=np.uint8).reshape(-1,256,512,3)
    assert len(frames)==len(records)
    if stack:
        from xr_stack_oracle import verify
        verify(out,frames,records,srgb=source_format.endswith("-srgb"))
        return out
    if panorama:
        panorama_frames=[frame for frame,record in zip(frames,records) if not record["projection"]]
        assert panorama_frames
        for frame in panorama_frames:
            # Uniform straight-alpha green sky fills both eyes over black.
            for eye in range(2):
                samples=frame[20:236,eye*256+20:eye*256+236]
                assert abs(float(samples[:,:,1].mean())-128)<15
                assert float(samples[:,:,(0,2)].mean())<15
        print("PASS: equirect2 loading sky, both eyes, alpha, projection transitions and image drain",flush=True)
        return out
    if cylinder:
        samples=[]
        for frame,record in zip(frames,records):
            for eye,view in enumerate(record["views"]):
                # Cylinder is head-relative, finite radius 2, angle 2.4, aspect 1.2.
                head=(np.array(record["views"][0]["position"])+record["views"][1]["position"])*.5
                q=view["orientation"]; inv=[-q[0],-q[1],-q[2],q[3]]
                origin=rotate(inv,np.array(view["position"])-head)
                left,right,up,down=map(math.tan,view["fov"])
                for px,py in ((80,90),(175,90),(80,175),(175,175)):
                    direction=np.array([left+(right-left)*(px+.5)/256,up+(down-up)*(py+.5)/256,-1.0])
                    direction/=np.linalg.norm(direction)
                    a=np.dot(direction[[0,2]],direction[[0,2]])
                    b=np.dot(origin[[0,2]],direction[[0,2]])
                    if cylinder_radius>0 and math.isfinite(cylinder_radius):
                        c=np.dot(origin[[0,2]],origin[[0,2]])-cylinder_radius*cylinder_radius
                        distance=(-b+math.sqrt(b*b-a*c))/a
                        hit=origin+direction*distance
                    else:
                        hit=direction
                    u=math.atan2(hit[0],-hit[2])/2.4+.5
                    v=.5-hit[1]/math.hypot(hit[0],hit[2])*1.2/2.4
                    assert .05<u<.95 and .05<v<.95
                    rgb=frame[py-1:py+2,eye*256+px-1:eye*256+px+2].mean(axis=(0,1))
                    expected=np.array([int(u*255)*.5,128,int(v*255)*.5])
                    if record["projection"]:
                        expected+=.5*np.array([255 if eye==0 and px<128 else 128 if eye==0 else 0,
                            64,255 if eye==1 and py<128 else 128 if eye==1 else 0])
                    assert np.max(np.abs(rgb-expected))<18,(eye,px,py,u,v,rgb,expected)
                    samples.append(rgb.tolist())
        (out / "cylinder-outcome.json").write_text(json.dumps({"outcome":"passed","samples":len(samples)}))
        print(f"PASS: patterned cylinder radius={cylinder_radius}, stereo UVs, alpha, projection transitions and image drain",flush=True)
        return out
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
    return out


if __name__=="__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("root",type=Path)
    parser.add_argument("--eye-size",type=int,default=256)
    parser.add_argument("--eye-height",type=int)
    parser.add_argument("--foveated",action="store_true")
    parser.add_argument("--hz",type=int,choices=(20,60,72),default=60)
    parser.add_argument("--codec",choices=("h264","h265"),default="h264")
    parser.add_argument("--bitrate",type=int,default=32)
    parser.add_argument("--live-bitrate",action="store_true")
    parser.add_argument("--live-foveation",action="store_true")
    parser.add_argument("--panorama",action="store_true")
    parser.add_argument("--layer-matrix",action="store_true")
    parser.add_argument("--cylinder",action="store_true")
    parser.add_argument("--cylinder-radius",type=float,default=2.0)
    parser.add_argument("--stack",action="store_true")
    parser.add_argument("--source-format",choices=("rgba8","bgra8","rgba8-srgb","bgra8-srgb"),default="rgba8")
    args=parser.parse_args()
    run(args.root.resolve(),args.eye_size,args.hz,args.codec,args.bitrate,args.live_bitrate,args.eye_height,args.foveated,args.live_foveation,args.panorama,args.layer_matrix,args.cylinder,args.cylinder_radius,args.stack,args.source_format)
