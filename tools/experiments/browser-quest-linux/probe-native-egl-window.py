#!/usr/bin/python3
"""Generated native X11 EGL swap test, independently of Chrome and media."""
import ctypes as c
import json
import signal
import time
signal.alarm(5)
r={'passed':False};dpy=display=surface=context=None;window=0

def fn(lib,name,result,args):
    f=getattr(lib,name);f.restype=result;f.argtypes=args;return f
class VisualInfo(c.Structure):
    _fields_=[('visual',c.c_void_p),('visualid',c.c_ulong),('screen',c.c_int),('depth',c.c_int),('visual_class',c.c_int),('red',c.c_ulong),('green',c.c_ulong),('blue',c.c_ulong),('colormap_size',c.c_int),('bits_per_rgb',c.c_int)]
class Attributes(c.Structure):
    _fields_=[('background_pixmap',c.c_ulong),('background_pixel',c.c_ulong),('border_pixmap',c.c_ulong),('border_pixel',c.c_ulong),('bit_gravity',c.c_int),('win_gravity',c.c_int),('backing_store',c.c_int),('backing_planes',c.c_ulong),('backing_pixel',c.c_ulong),('save_under',c.c_int),('event_mask',c.c_long),('do_not_propagate_mask',c.c_long),('override_redirect',c.c_int),('colormap',c.c_ulong),('cursor',c.c_ulong)]
try:
    x=c.CDLL('libX11.so.6');egl=c.CDLL('libEGL.so.1');gl=c.CDLL('libGLESv2.so.2')
    dpy=fn(x,'XOpenDisplay',c.c_void_p,[c.c_char_p])(b':9')
    if not dpy:raise RuntimeError('Native display unavailable')
    root=fn(x,'XDefaultRootWindow',c.c_ulong,[c.c_void_p])(dpy)
    display=fn(egl,'eglGetDisplay',c.c_void_p,[c.c_void_p])(dpy)
    major,minor=c.c_int(),c.c_int()
    error=fn(egl,'eglGetError',c.c_uint,[])
    if not fn(egl,'eglInitialize',c.c_uint,[c.c_void_p,c.POINTER(c.c_int),c.POINTER(c.c_int)])(display,c.byref(major),c.byref(minor)):raise RuntimeError('EGL initialize '+hex(error()))
    r['egl_version']=[major.value,minor.value]
    fn(egl,'eglBindAPI',c.c_uint,[c.c_uint])(0x30A0)
    attrs=(c.c_int*11)(0x3033,4,0x3040,4,0x3024,8,0x3023,8,0x3022,8,0x3038)
    config=c.c_void_p();count=c.c_int()
    if not fn(egl,'eglChooseConfig',c.c_uint,[c.c_void_p,c.POINTER(c.c_int),c.POINTER(c.c_void_p),c.c_int,c.POINTER(c.c_int)])(display,attrs,c.byref(config),1,c.byref(count)) or count.value<1:raise RuntimeError('Native EGL config '+hex(error()))
    visual_id=c.c_int()
    if not fn(egl,'eglGetConfigAttrib',c.c_uint,[c.c_void_p,c.c_void_p,c.c_int,c.POINTER(c.c_int)])(display,config,0x302E,c.byref(visual_id)):raise RuntimeError('No native visual')
    template=VisualInfo();template.visualid=visual_id.value
    visuals=fn(x,'XGetVisualInfo',c.POINTER(VisualInfo),[c.c_void_p,c.c_long,c.POINTER(VisualInfo),c.POINTER(c.c_int)])(dpy,1,c.byref(template),c.byref(count))
    if not visuals or count.value<1:raise RuntimeError('Native visual missing')
    visual=visuals[0];a=Attributes()
    a.colormap=fn(x,'XCreateColormap',c.c_ulong,[c.c_void_p,c.c_ulong,c.c_void_p,c.c_int])(dpy,root,visual.visual,0)
    a.event_mask=(1<<15)|(1<<17)
    window=fn(x,'XCreateWindow',c.c_ulong,[c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_uint,c.c_int,c.c_uint,c.c_void_p,c.c_ulong,c.POINTER(Attributes)])(dpy,root,100,100,256,128,0,visual.depth,1,visual.visual,(1<<3)|(1<<11)|(1<<13),c.byref(a))
    fn(x,'XFree',c.c_int,[c.c_void_p])(visuals)
    fn(x,'XMapRaised',c.c_int,[c.c_void_p,c.c_ulong])(dpy,window)
    fn(x,'XSync',c.c_int,[c.c_void_p,c.c_int])(dpy,0)
    context=fn(egl,'eglCreateContext',c.c_void_p,[c.c_void_p,c.c_void_p,c.c_void_p,c.POINTER(c.c_int)])(display,config,None,(c.c_int*3)(0x3098,2,0x3038))
    surface=fn(egl,'eglCreateWindowSurface',c.c_void_p,[c.c_void_p,c.c_void_p,c.c_ulong,c.c_void_p])(display,config,window,None)
    current=fn(egl,'eglMakeCurrent',c.c_uint,[c.c_void_p,c.c_void_p,c.c_void_p,c.c_void_p])
    if not context or not surface or not current(display,surface,surface,context):raise RuntimeError('Native EGL surface/context '+hex(error()))
    renderer=fn(gl,'glGetString',c.c_char_p,[c.c_uint])(0x1F01);r['renderer']=renderer.decode() if renderer else ''
    clear=fn(gl,'glClearColor',None,[c.c_float]*4);draw=fn(gl,'glClear',None,[c.c_uint]);finish=fn(gl,'glFinish',None,[])
    read=fn(gl,'glReadPixels',None,[c.c_int]*4+[c.c_uint,c.c_uint,c.c_void_p])
    swap=fn(egl,'eglSwapBuffers',c.c_uint,[c.c_void_p,c.c_void_p]);interval=fn(egl,'eglSwapInterval',c.c_uint,[c.c_void_p,c.c_int])
    get=fn(x,'XGetImage',c.c_void_p,[c.c_void_p,c.c_ulong,c.c_int,c.c_int,c.c_uint,c.c_uint,c.c_ulong,c.c_int]);pixel_fn=fn(x,'XGetPixel',c.c_ulong,[c.c_void_p,c.c_int,c.c_int]);destroy=fn(x,'XDestroyImage',c.c_int,[c.c_void_p])
    samples=[]
    for pacing in (0,1):
        interval(display,pacing)
        for color,expected in [((1.,0.,0.,1.),0xff0000),((0.,1.,0.,1.),0x00ff00),((0.,0.,1.,1.),0x0000ff)]:
            clear(*color);draw(0x4000);finish()
            internal=(c.c_ubyte*4)();read(0,0,1,1,0x1908,0x1401,internal)
            start=time.monotonic();ok=bool(swap(display,surface));elapsed=(time.monotonic()-start)*1000
            time.sleep(.04)
            image=get(dpy,window,50,50,1,1,c.c_ulong(-1),2)
            actual=pixel_fn(image,0,0)&0xffffff if image else None
            if image:destroy(image)
            samples.append({'interval':pacing,'swap_ok':ok,'swap_ms':round(elapsed,2),'expected':expected,'native_pixel':actual,'internal_pixel':list(internal)})
    r['samples']=samples;r['passed']=all(s['swap_ok'] and s['native_pixel']==s['expected'] for s in samples)
except Exception as e:r['error']=type(e).__name__+': '+str(e)
finally:
    if display:
        if 'current' in globals():current(display,None,None,None)
        if surface:fn(egl,'eglDestroySurface',c.c_uint,[c.c_void_p,c.c_void_p])(display,surface)
        if context:fn(egl,'eglDestroyContext',c.c_uint,[c.c_void_p,c.c_void_p])(display,context)
        fn(egl,'eglTerminate',c.c_uint,[c.c_void_p])(display)
    if dpy:
        if window:fn(x,'XDestroyWindow',c.c_int,[c.c_void_p,c.c_ulong])(dpy,window)
        fn(x,'XCloseDisplay',c.c_int,[c.c_void_p])(dpy)
print(json.dumps(r))
