#!/usr/bin/python3
"""Bounded generated Surface frames; optional Xvfb, never Chrome/video."""
import argparse
import ctypes as c
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import time
parser=argparse.ArgumentParser()
parser.add_argument('--x11-mode',choices=('off','startup','idle','capture','idle-gles','capture-gles'),default='off')
args=parser.parse_args()
signal.alarm(8)
spec=importlib.util.spec_from_file_location('capture','/tmp/gpu-x11-capture.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
capture=None;xserver=None;xlog=None;x=None;dpy=None;window=0;gc=None
result={'passed':False,'source':'generated-no-video','x11_mode':args.x11_mode}
try:
    policy_file=Path('/tmp/nf-gpu-driver-policy')
    result['driver_policy']=module.apply_driver_policy(policy_file.read_text().strip() if policy_file.exists() else 'default')
    if args.x11_mode!='off':
        env=dict(os.environ,NF_XVFB_READBACK_MS='0')
        if args.x11_mode.endswith('-gles'):env['NF_XVFB_GLES']='1'
        xlog=open('/tmp/generated-surface-xvfb.log','w')
        xserver=subprocess.Popen(['/opt/nightfall-xvfb/Xvfb',':9','-screen','0','1280x720x24','-noreset','-vfbdevice','/dev/kgsl-3d0','-nolisten','tcp','-ac','-nocursor'],env=env,stdout=xlog,stderr=subprocess.STDOUT)
        x=c.CDLL('libX11.so.6');fn=module.fn
        opened=fn(x,'XOpenDisplay',c.c_void_p,[c.c_char_p])
        deadline=time.monotonic()+2
        while time.monotonic()<deadline:
            if xserver.poll() is not None:raise RuntimeError('Generated Xvfb exited')
            dpy=opened(b':9')
            if dpy:break
            time.sleep(.025)
        if not dpy:raise RuntimeError('Generated Xvfb unavailable')
        if args.x11_mode!='startup':
            root=fn(x,'XDefaultRootWindow',c.c_ulong,[c.c_void_p])(dpy)
            window=fn(x,'XCreateSimpleWindow',c.c_ulong,[c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_uint,c.c_ulong,c.c_ulong])(dpy,root,0,0,1280,720,0,0,0)
            if not window:raise RuntimeError('Generated X11 window unavailable')
            fn(x,'XStoreName',c.c_int,[c.c_void_p,c.c_ulong,c.c_char_p])(dpy,window,b'nf-generated-test')
            fn(x,'XMapWindow',c.c_int,[c.c_void_p,c.c_ulong])(dpy,window)
            gc=fn(x,'XCreateGC',c.c_void_p,[c.c_void_p,c.c_ulong,c.c_ulong,c.c_void_p])(dpy,window,0,None)
            if not gc:raise RuntimeError('Generated X11 GC unavailable')
            x_sync=fn(x,'XSync',c.c_int,[c.c_void_p,c.c_int]);x_sync(dpy,0)
            if args.x11_mode.endswith('-gles'):
                diagnostics=Path('/tmp/generated-surface-xvfb.log').read_text(errors='replace')
                if 'NF_XVFB_CONTEXT_API=OpenGL ES' not in diagnostics or 'NF_XVFB_GLES_GLAMOR_READY=1' not in diagnostics or not any(tag in diagnostics for tag in ('renderer=FD7','renderer=FD6')):raise RuntimeError('Hardware GLES Xvfb precondition failed')
                result['xvfb_gles_verified']=True
            foreground=fn(x,'XSetForeground',c.c_int,[c.c_void_p,c.c_void_p,c.c_ulong])
            fill=fn(x,'XFillRectangle',c.c_int,[c.c_void_p,c.c_ulong,c.c_void_p,c.c_int,c.c_int,c.c_uint,c.c_uint])
    capture=module.GpuCapture(dict(os.environ),display=':9',window=window,mode='composite' if args.x11_mode.startswith('capture') else 'generated')
    started=time.monotonic()
    for frame in range(120):
        if dpy and gc:
            foreground(dpy,gc,0xff40bf if frame<60 else 0x0040bf)
            fill(dpy,window,gc,0,0,1280,720);x_sync(dpy,0)
        capture.frame()
        time.sleep(max(0,started+(frame+1)/60-time.monotonic()))
    result.update(passed=True,frames=capture.frames,release_fences=capture.release_fences,elapsed_s=round(time.monotonic()-started,3))
except Exception as error:result['error']=type(error).__name__+': '+str(error)
finally:
    if capture is not None:
        try:capture.close()
        except Exception as error:result.update(passed=False,cleanup_error=type(error).__name__)
    if dpy:
        if gc:module.fn(x,'XFreeGC',c.c_int,[c.c_void_p,c.c_void_p])(dpy,gc)
        if window:module.fn(x,'XDestroyWindow',c.c_int,[c.c_void_p,c.c_ulong])(dpy,window)
        module.fn(x,'XCloseDisplay',c.c_int,[c.c_void_p])(dpy)
    if xserver is not None:
        xserver.terminate()
        try:xserver.wait(timeout=.5)
        except subprocess.TimeoutExpired:xserver.kill();xserver.wait(timeout=.5)
    if xlog is not None:xlog.close()
    Path('/tmp/gpu-generated-surface-status.json').write_text(json.dumps(result))
print(json.dumps(result),flush=True)
raise SystemExit(0 if result['passed'] else 1)
