#!/usr/bin/python3
"""Decode 60 generated H.264 frames through VA-API and download NV12 output.
No software fallback is requested: failed VA decoding is a failed experiment.
"""
import json
import subprocess
import time
r={'passed':False,'requested_frames':60,'output':'downloaded NV12, discarded'}
start=time.monotonic()
try:
    p=subprocess.run(['/usr/bin/ffmpeg','-hide_banner','-nostdin','-nostats','-loglevel','verbose',
        '-init_hw_device','vaapi=va:/dev/kgsl-3d0','-hwaccel','vaapi','-hwaccel_device','va',
        '-hwaccel_output_format','vaapi','-i','/tmp/nf-generated-video.mp4',
        '-an','-frames:v','60','-vf','hwdownload,format=nv12','-progress','pipe:1',
        '-benchmark','-f','null','-'],capture_output=True,text=True,timeout=6)
    r['exit']=p.returncode;r['diagnostics']=p.stderr[-9000:]
    values={}
    for line in p.stdout.splitlines():
        if '=' in line:
            key,value=line.split('=',1);values[key]=value
    r['progress']=values
    r['passed']=p.returncode==0 and int(values.get('frame','0'))==60
except subprocess.TimeoutExpired as e:
    r['error']='Six-second decode deadline exceeded'
    r['diagnostics']=(e.stderr or b'').decode(errors='replace')[-14000:]
except Exception as e:r['error']=type(e).__name__+': '+str(e)
r['elapsed_ms']=round((time.monotonic()-start)*1000,2)
print(json.dumps(r))
