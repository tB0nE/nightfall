#!/usr/bin/python3
"""Live GPU capture of the owned Chrome PID. Never reads page titles/URLs/profile.
Lifetime follows the native Surface socket; no production session time limit.
"""
import ctypes as c
import importlib.util
import json
import os
from pathlib import Path
import signal
import time
spec=importlib.util.spec_from_file_location('capture','/tmp/gpu-x11-capture.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
fn=module.fn

def owned_window(pid,display):
    x=c.CDLL('libX11.so.6');dpy=fn(x,'XOpenDisplay',c.c_void_p,[c.c_char_p])(display.encode())
    if not dpy:return None
    class Attributes(c.Structure):
        _fields_=[('x',c.c_int),('y',c.c_int),('width',c.c_int),('height',c.c_int),('border',c.c_int),('depth',c.c_int),('visual',c.c_void_p),('root',c.c_ulong),('cls',c.c_int),('bit_gravity',c.c_int),('win_gravity',c.c_int),('backing_store',c.c_int),('planes',c.c_ulong),('pixel',c.c_ulong),('save',c.c_int),('colormap',c.c_ulong),('map_installed',c.c_int),('map_state',c.c_int),('all_events',c.c_long),('your_events',c.c_long),('propagate',c.c_long),('override',c.c_int),('screen',c.c_void_p)]
    handler=c.CFUNCTYPE(c.c_int,c.c_void_p,c.c_void_p)(lambda d,e:0)
    previous=fn(x,'XSetErrorHandler',c.c_void_p,[c.c_void_p])(handler)
    children=c.POINTER(c.c_ulong)();result=None
    try:
        root=fn(x,'XDefaultRootWindow',c.c_ulong,[c.c_void_p])(dpy)
        parent=c.c_ulong();returned_root=c.c_ulong();count=c.c_uint()
        if not fn(x,'XQueryTree',c.c_int,[c.c_void_p,c.c_ulong,c.POINTER(c.c_ulong),c.POINTER(c.c_ulong),c.POINTER(c.POINTER(c.c_ulong)),c.POINTER(c.c_uint)])(dpy,root,c.byref(returned_root),c.byref(parent),c.byref(children),c.byref(count)):return None
        atom=fn(x,'XInternAtom',c.c_ulong,[c.c_void_p,c.c_char_p,c.c_int])(dpy,b'_NET_WM_PID',1)
        candidates=[]
        for window in children[:count.value]:
            kind=c.c_ulong();fmt=c.c_int();items=c.c_ulong();after=c.c_ulong();data=c.c_void_p()
            fn(x,'XGetWindowProperty',c.c_int,[c.c_void_p,c.c_ulong,c.c_ulong,c.c_long,c.c_long,c.c_int,c.c_ulong,c.POINTER(c.c_ulong),c.POINTER(c.c_int),c.POINTER(c.c_ulong),c.POINTER(c.c_ulong),c.POINTER(c.c_void_p)])(dpy,window,atom,0,1,0,6,c.byref(kind),c.byref(fmt),c.byref(items),c.byref(after),c.byref(data))
            owner=c.cast(data,c.POINTER(c.c_ulong))[0] if data and fmt.value==32 and items.value==1 else -1
            if data:fn(x,'XFree',c.c_int,[c.c_void_p])(data)
            if owner!=pid:continue
            attributes=Attributes()
            if fn(x,'XGetWindowAttributes',c.c_int,[c.c_void_p,c.c_ulong,c.POINTER(Attributes)])(dpy,window,c.byref(attributes)) and attributes.map_state==2 and attributes.width>300 and attributes.height>200:
                candidates.append(window)
        if len(candidates)==1:result=candidates[0]
    finally:
        if children:fn(x,'XFree',c.c_int,[c.c_void_p])(children)
        fn(x,'XCloseDisplay',c.c_int,[c.c_void_p])(dpy)
        fn(x,'XSetErrorHandler',c.c_void_p,[c.c_void_p])(previous)
    return result

def main():
    capture=None;started=time.monotonic();result={'state':'starting','allowed_cpus':sorted(os.sched_getaffinity(0))}
    signal.signal(signal.SIGTERM,lambda *_:(_ for _ in ()).throw(SystemExit(0)))
    try:
        policy_path=Path('/tmp/nf-gpu-driver-policy')
        policy=policy_path.read_text().strip() if policy_path.exists() else 'default'
        result['driver_policy']=module.apply_driver_policy(policy)
        deadline=time.monotonic()+6
        while time.monotonic()<deadline:
            try:
                pid=int(Path('/tmp/nightfall-chrome.pid').read_text());os.kill(pid,0)
                window=owned_window(pid,':1')
                if window:break
            except (OSError,ValueError):pass
            time.sleep(.05)
        else:raise RuntimeError('Owned Chrome window unavailable')
        mode_path=Path('/tmp/nf-gpu-capture-mode')
        mode=mode_path.read_text().strip() if mode_path.exists() else 'composite'
        result['capture_mode']=mode
        capture=module.GpuCapture(dict(os.environ),display=':1',window=window,mode=mode)
        next_frame=time.monotonic();next_config=0;hz=60
        while True:
            if time.monotonic()>=next_config:
                try:
                    wanted=int(Path('/tmp/nf-gpu-target-hz').read_text())
                    if 30<=wanted<=120:hz=wanted
                except (OSError,ValueError):pass
                next_config=time.monotonic()+.5
            capture.frame()
            next_frame=max(next_frame+1/hz,time.monotonic())
            time.sleep(max(0,next_frame-time.monotonic()))
    except (EOFError,BrokenPipeError,ConnectionResetError):result['state']='stopped'
    except SystemExit:result['state']='stopped'
    except Exception as error:result.update(state='error',error=type(error).__name__,stage=str(error)[:160])
    finally:
        if capture is not None:
            result.update(frames=capture.frames,release_fences=capture.release_fences,source_size=capture.source_size)
            try:capture.close()
            except Exception as error:result['cleanup_error']=type(error).__name__
        result['elapsed_s']=round(time.monotonic()-started,3)
        Path('/tmp/gpu-live-status.json').write_text(json.dumps(result))
    return 0 if result['state']=='stopped' else 1
if __name__=='__main__':raise SystemExit(main())
