"""Independent decoded-pixel oracle for the ordered, colour-transformed fixture."""
import json
import math
import re
import numpy as np


def rotate(q,v):
    xyz=np.array(q[:3]); t=2*np.cross(xyz,v)
    return v+q[3]*t+np.cross(xyz,t)


def verify(out,frames,records,srgb=False):
    log=(out / "application-live.log").read_text()
    source_frames={int(timestamp):int(frame) for frame,timestamp in
        re.findall(r"Frame (\d+) monotonic_ns=(\d+)",log)}
    tracked={int(frame):np.array([float(x),float(y),float(z)]) for frame,x,y,z in
        re.findall(r"Tracked view frame=(\d+) left_position=([-\d.]+),([-\d.]+),([-\d.]+)",log)}
    modes=set(); samples=0
    def linear(value):
        value=np.array(value)
        if not srgb:return value
        return np.where(value<=.04045,value/12.92,((value+.055)/1.055)**2.4)
    def encoded(value):
        if not srgb:return value
        return np.where(value<=.0031308,value*12.92,1.055*np.maximum(value,0)**(1/2.4)-.055)
    def transform(rgba,scale,bias):
        value=np.clip(np.array(rgba)*scale+bias,0,1)
        return value[:3]*value[3],value[3]
    def over(source,destination):
        if source is None:return destination
        rgb,alpha=source
        return rgb+destination*(1-alpha)
    overlay=transform([0,1,0,128/255],np.array([.3,.4,.5,.6]),np.array([.04,.02,.06,.1]))
    for frame,record in zip(frames,records):
        number=source_frames[record["source_time_ns"]]
        mode=(number//4)%10; modes.add(mode)
        if mode==9:
            assert np.linalg.norm(np.array(record["views"][0]["position"])-tracked[number])<.05
        for eye,view in enumerate(record["views"]):
            left,right,up,down=map(math.tan,view["fov"])
            for px,py in ((32,70),(90,180),(165,70),(225,180)):
                ray=np.array([left+(right-left)*(px+.5)/256,up+(down-up)*(py+.5)/256,-1.0])
                def projection(second=False,cropped=False,identity=False):
                    direction=ray
                    l,r,u,d=left,right,up,down
                    if second:
                        world=rotate(view["orientation"],ray)
                        direction=rotate([0,-math.sin(.06),0,math.cos(.06)],world)
                        l,r,u,d=np.array([l,r,u,d])*.65
                    if direction[2]>=0:return None
                    tangent=direction[:2]/-direction[2]
                    sx=(tangent[0]-l)/(r-l); sy=(u-tangent[1])/(u-d)
                    if not (0<=sx<=1 and 0<=sy<=1):return None
                    if cropped:sx*=.5
                    rgba=[(255 if sx<.5 else 128)/255 if eye==0 else 0,64/255,
                        (255 if sy<.5 else 128)/255 if eye==1 else 0,1]
                    rgba[:3]=linear(rgba[:3])
                    if identity:return np.array(rgba[:3]),1
                    if second:return transform(rgba,np.array([.25,.5,.75,.25]),np.array([.02,.04,.01,0]))
                    return transform(rgba,np.array([.8,.6,.4,.5]),np.array([.05,.03,.02,0]))
                expected=np.zeros(3)
                if mode in (0,9):expected=over(projection(),expected)
                elif mode==1:expected=over(projection(),over(overlay,expected))
                elif mode==2:expected=over(projection(second=True),over(overlay,over(projection(),expected)))
                elif mode in (3,4):expected=over(overlay,expected)
                elif mode==5:expected=np.array([.04,float(linear(128/255))*.4+.02,.06])
                elif mode==6:expected=over(projection(cropped=True),expected)
                elif mode==7:expected=over(projection(identity=True),expected)
                elif mode==8:expected=np.array([.3,1,.5])
                actual=frame[py-1:py+2,eye*256+px-1:eye*256+px+2].mean(axis=(0,1))
                expected=encoded(expected)*255
                assert np.max(np.abs(actual-expected))<20,(mode,eye,px,py,actual,expected)
                samples+=1
    assert modes==set(range(10)),modes
    service=(out / "service.log").read_text()
    assert "METEOR_RENDER_PATH mode=general" in service
    assert "METEOR_RENDER_PATH mode=copy" in service
    result={"outcome":"passed","modes":sorted(modes),"pixel_samples":samples}
    (out / "stack-outcome.json").write_text(json.dumps(result,indent=2)+"\n")
    print("PASS: colour transforms on all layer types, ordered projections/overlays, rotated FOV, resized sources and copy-path return",flush=True)
