#!/usr/bin/python3
"""Guest-only generated linear GBM -> DRI3 pixmap -> root copy test."""
import ctypes as c
import json
import os
import signal
import time
signal.alarm(4)
r={'passed':False};device=bo=dpy=connection=None;fd=-1
try:
    gbm=c.CDLL('libgbm.so.1');xlib=c.CDLL('libX11.so.6');xcb=c.CDLL('libxcb.so.1');dri=c.CDLL('libxcb-dri3.so.0')
    def fn(lib,name,result,args):
        f=getattr(lib,name);f.restype=result;f.argtypes=args;return f
    fd=os.open('/dev/kgsl-3d0',os.O_RDWR)
    device=fn(gbm,'gbm_create_device',c.c_void_p,[c.c_int])(fd)
    if not device:raise RuntimeError('GBM device unavailable')
    bo=fn(gbm,'gbm_bo_create',c.c_void_p,[c.c_void_p,c.c_uint,c.c_uint,c.c_uint,c.c_uint])(device,128,128,0x34325258,4|16)
    if not bo:raise RuntimeError('Linear GBM buffer unavailable')
    stride=c.c_uint();mapping=c.c_void_p()
    memory=fn(gbm,'gbm_bo_map',c.c_void_p,[c.c_void_p,c.c_uint,c.c_uint,c.c_uint,c.c_uint,c.c_uint,c.POINTER(c.c_uint),c.POINTER(c.c_void_p)])(bo,0,0,128,128,2,c.byref(stride),c.byref(mapping))
    if not memory:raise RuntimeError('GBM CPU write mapping unavailable')
    for y in range(128):
        row=(c.c_uint32*128).from_address(memory+y*stride.value)
        for x in range(128):row[x]=0xffff0000
    fn(gbm,'gbm_bo_unmap',None,[c.c_void_p,c.c_void_p])(bo,mapping)
    buffer_fd=fn(gbm,'gbm_bo_get_fd',c.c_int,[c.c_void_p])(bo)
    if buffer_fd<0:raise RuntimeError('Buffer FD export failed')
    expected=0xff0000
    if os.environ.get('NF_DRI3_GPU_PAINT')=='1':
        import importlib.util
        spec=importlib.util.spec_from_file_location('paint','/tmp/paint-generated-dmabuf.py');paint=importlib.util.module_from_spec(spec);spec.loader.exec_module(paint)
        r['gpu_producer_pixel']=paint.paint(buffer_fd,stride.value,128,128)
        expected=0x0000ff
    dpy=fn(xlib,'XOpenDisplay',c.c_void_p,[c.c_char_p])(b':9')
    if not dpy:raise RuntimeError('X display unavailable')
    root=fn(xlib,'XDefaultRootWindow',c.c_ulong,[c.c_void_p])(dpy)
    screen=c.c_int();connection=fn(xcb,'xcb_connect',c.c_void_p,[c.c_char_p,c.POINTER(c.c_int)])(b':9',c.byref(screen))
    pixmap=fn(xcb,'xcb_generate_id',c.c_uint,[c.c_void_p])(connection)
    class Cookie(c.Structure):_fields_=[('sequence',c.c_uint)]
    cookie=fn(dri,'xcb_dri3_pixmap_from_buffer_checked',Cookie,[c.c_void_p,c.c_uint,c.c_uint,c.c_uint,c.c_uint16,c.c_uint16,c.c_uint16,c.c_uint8,c.c_uint8,c.c_int])(connection,pixmap,root,stride.value*128,128,128,stride.value,24,32,buffer_fd)
    error=fn(xcb,'xcb_request_check',c.c_void_p,[c.c_void_p,Cookie])(connection,cookie)
    if error:
        r['x11_error_code']=(c.c_ubyte*2).from_address(error)[1]
        fn(c.CDLL(None),'free',None,[c.c_void_p])(error)
        raise RuntimeError('DRI3 pixmap import rejected')
    gc=fn(xlib,'XDefaultGC',c.c_void_p,[c.c_void_p,c.c_int])(dpy,0)
    fn(xlib,'XCopyArea',c.c_int,[c.c_void_p,c.c_ulong,c.c_ulong,c.c_void_p,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_int,c.c_int])(dpy,pixmap,root,gc,0,0,128,128,400,200)
    fn(xlib,'XSync',c.c_int,[c.c_void_p,c.c_int])(dpy,0)
    image=fn(xlib,'XGetImage',c.c_void_p,[c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_ulong,c.c_int])(dpy,root,450,250,1,1,c.c_ulong(-1),2)
    if not image:raise RuntimeError('Copied pixel unavailable')
    r['pixel']=fn(xlib,'XGetPixel',c.c_ulong,[c.c_void_p,c.c_int,c.c_int])(image,0,0)&0xffffff
    fn(xlib,'XDestroyImage',c.c_int,[c.c_void_p])(image)
    r['passed']=r['pixel']==expected;r['stride']=stride.value
    window=fn(xlib,'XCreateSimpleWindow',c.c_ulong,[c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_uint,c.c_ulong,c.c_ulong])(dpy,root,400,200,128,128,0,0,0)
    fn(xlib,'XMapRaised',c.c_int,[c.c_void_p,c.c_ulong])(dpy,window)
    fn(xlib,'XSync',c.c_int,[c.c_void_p,c.c_int])(dpy,0)
    present=c.CDLL('libxcb-present.so.0')
    present_fn=fn(present,'xcb_present_pixmap_checked',Cookie,[c.c_void_p,c.c_uint,c.c_uint,c.c_uint,c.c_uint,c.c_uint,c.c_int16,c.c_int16,c.c_uint,c.c_uint,c.c_uint,c.c_uint,c.c_uint64,c.c_uint64,c.c_uint64,c.c_uint,c.c_void_p])
    results=[]
    for options in (0,2):
        cookie=present_fn(connection,window,pixmap,options+1,0,0,0,0,0,0,0,options,0,0,0,0,None)
        error=fn(xcb,'xcb_request_check',c.c_void_p,[c.c_void_p,Cookie])(connection,cookie)
        entry={'options':options}
        if error:
            entry['x11_error']=(c.c_ubyte*2).from_address(error)[1]
            fn(c.CDLL(None),'free',None,[c.c_void_p])(error)
        else:
            time.sleep(.1)
            image=fn(xlib,'XGetImage',c.c_void_p,[c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_ulong,c.c_int])(dpy,window,50,50,1,1,c.c_ulong(-1),2)
            if image:
                entry['pixel']=fn(xlib,'XGetPixel',c.c_ulong,[c.c_void_p,c.c_int,c.c_int])(image,0,0)&0xffffff
                fn(xlib,'XDestroyImage',c.c_int,[c.c_void_p])(image)
        results.append(entry)
    r['present_tests']=results
    r['passed']=r['passed'] and all(item.get('pixel')==expected for item in results)
    fence_lib=c.CDLL('libxshmfence.so.1')
    fence_fd=fn(fence_lib,'xshmfence_alloc_shm',c.c_int,[])()
    if fence_fd<0:raise RuntimeError('Shared fence allocation failed')
    fence_map=fn(fence_lib,'xshmfence_map_shm',c.c_void_p,[c.c_int])(fence_fd)
    if not fence_map:raise RuntimeError('Shared fence mapping failed')
    try:
        fn(fence_lib,'xshmfence_reset',None,[c.c_void_p])(fence_map)
        fence_id=fn(xcb,'xcb_generate_id',c.c_uint,[c.c_void_p])(connection)
        cookie=fn(dri,'xcb_dri3_fence_from_fd_checked',Cookie,[c.c_void_p,c.c_uint,c.c_uint,c.c_uint8,c.c_int])(connection,window,fence_id,0,os.dup(fence_fd))
        error=fn(xcb,'xcb_request_check',c.c_void_p,[c.c_void_p,Cookie])(connection,cookie)
        if error:raise RuntimeError('DRI3 fence import failed')
        fn(xlib,'XSetForeground',c.c_int,[c.c_void_p,c.c_void_p,c.c_ulong])(dpy,gc,0x00ff00)
        fn(xlib,'XFillRectangle',c.c_int,[c.c_void_p,c.c_ulong,c.c_void_p,c.c_int,c.c_int,c.c_uint,c.c_uint])(dpy,window,gc,0,0,128,128)
        fn(xlib,'XSync',c.c_int,[c.c_void_p,c.c_int])(dpy,0)
        cookie=present_fn(connection,window,pixmap,10,0,0,0,0,0,fence_id,0,0,0,0,0,0,None)
        error=fn(xcb,'xcb_request_check',c.c_void_p,[c.c_void_p,Cookie])(connection,cookie)
        if error:raise RuntimeError('Fenced Present request failed')
        fn(fence_lib,'xshmfence_trigger',c.c_int,[c.c_void_p])(fence_map)
        time.sleep(.1)
        image=fn(xlib,'XGetImage',c.c_void_p,[c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_ulong,c.c_int])(dpy,window,50,50,1,1,c.c_ulong(-1),2)
        if image:
            r['fenced_present_pixel']=fn(xlib,'XGetPixel',c.c_ulong,[c.c_void_p,c.c_int,c.c_int])(image,0,0)&0xffffff
            fn(xlib,'XDestroyImage',c.c_int,[c.c_void_p])(image)
    finally:
        r['passed']=r['passed'] and r.get('fenced_present_pixel')==expected
        fn(fence_lib,'xshmfence_unmap_shm',None,[c.c_void_p])(fence_map);os.close(fence_fd)


except Exception as e:r['passed']=False;r['error']=type(e).__name__+': '+str(e)
finally:
    if dpy:fn(xlib,'XCloseDisplay',c.c_int,[c.c_void_p])(dpy)
    if connection:fn(xcb,'xcb_disconnect',None,[c.c_void_p])(connection)
    if bo:fn(gbm,'gbm_bo_destroy',None,[c.c_void_p])(bo)
    if device:fn(gbm,'gbm_device_destroy',None,[c.c_void_p])(device)
    if fd>=0:os.close(fd)
print(json.dumps(r))
