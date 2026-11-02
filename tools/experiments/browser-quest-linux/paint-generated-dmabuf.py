#!/usr/bin/python3
"""Shared helper: paint a generated linear XRGB dma-buf with GLES, not a video."""
import ctypes as c

def paint(fd,stride,width,height,color=(0,0,1,1),fourcc=0x34325258):
    egl=c.CDLL('libEGL.so.1');gl=c.CDLL('libGLESv2.so.2')
    def f(lib,name,result,args):
        value=getattr(lib,name);value.restype=result;value.argtypes=args;return value
    display=f(egl,'eglGetDisplay',c.c_void_p,[c.c_void_p])(None)
    a,b=c.c_int(),c.c_int()
    if not f(egl,'eglInitialize',c.c_uint,[c.c_void_p,c.POINTER(c.c_int),c.POINTER(c.c_int)])(display,c.byref(a),c.byref(b)):raise RuntimeError('GPU producer EGL init failed')
    config=c.c_void_p();count=c.c_int();attrs=(c.c_int*7)(0x3033,1,0x3040,4,0x3024,8,0x3038)
    f(egl,'eglBindAPI',c.c_uint,[c.c_uint])(0x30A0)
    if not f(egl,'eglChooseConfig',c.c_uint,[c.c_void_p,c.POINTER(c.c_int),c.POINTER(c.c_void_p),c.c_int,c.POINTER(c.c_int)])(display,attrs,c.byref(config),1,c.byref(count)) or count.value<1:raise RuntimeError('GPU producer EGL config failed')
    ctx=f(egl,'eglCreateContext',c.c_void_p,[c.c_void_p,c.c_void_p,c.c_void_p,c.POINTER(c.c_int)])(display,config,None,(c.c_int*3)(0x3098,2,0x3038))
    surf=f(egl,'eglCreatePbufferSurface',c.c_void_p,[c.c_void_p,c.c_void_p,c.POINTER(c.c_int)])(display,config,(c.c_int*5)(0x3057,1,0x3056,1,0x3038))
    current=f(egl,'eglMakeCurrent',c.c_uint,[c.c_void_p,c.c_void_p,c.c_void_p,c.c_void_p])
    if not ctx or not surf or not current(display,surf,surf,ctx):raise RuntimeError('GPU producer context failed')
    proc=f(egl,'eglGetProcAddress',c.c_void_p,[c.c_char_p])
    create=c.CFUNCTYPE(c.c_void_p,c.c_void_p,c.c_void_p,c.c_uint,c.c_void_p,c.POINTER(c.c_int))(proc(b'eglCreateImageKHR'))
    attrs=(c.c_int*13)(0x3057,width,0x3056,height,0x3271,fourcc,0x3272,fd,0x3273,0,0x3274,stride,0x3038)
    image=create(display,None,0x3270,None,attrs)
    if not image:raise RuntimeError('GPU producer dma-buf import failed')
    texture=c.c_uint();frame=c.c_uint()
    f(gl,'glGenTextures',None,[c.c_int,c.POINTER(c.c_uint)])(1,c.byref(texture))
    f(gl,'glBindTexture',None,[c.c_uint,c.c_uint])(0x0DE1,texture)
    target=c.CFUNCTYPE(None,c.c_uint,c.c_void_p)(proc(b'glEGLImageTargetTexture2DOES'));target(0x0DE1,image)
    f(gl,'glGenFramebuffers',None,[c.c_int,c.POINTER(c.c_uint)])(1,c.byref(frame))
    f(gl,'glBindFramebuffer',None,[c.c_uint,c.c_uint])(0x8D40,frame)
    f(gl,'glFramebufferTexture2D',None,[c.c_uint,c.c_uint,c.c_uint,c.c_uint,c.c_int])(0x8D40,0x8CE0,0x0DE1,texture,0)
    if f(gl,'glCheckFramebufferStatus',c.c_uint,[c.c_uint])(0x8D40)!=0x8CD5:raise RuntimeError('GPU producer framebuffer incomplete')
    f(gl,'glClearColor',None,[c.c_float]*4)(*color);f(gl,'glClear',None,[c.c_uint])(0x4000)
    f(gl,'glFinish',None,[])()
    pixel=(c.c_ubyte*4)();f(gl,'glReadPixels',None,[c.c_int]*4+[c.c_uint,c.c_uint,c.c_void_p])(0,0,1,1,0x1908,0x1401,pixel)
    result=list(pixel)
    f(gl,'glDeleteFramebuffers',None,[c.c_int,c.POINTER(c.c_uint)])(1,c.byref(frame));f(gl,'glDeleteTextures',None,[c.c_int,c.POINTER(c.c_uint)])(1,c.byref(texture))
    c.CFUNCTYPE(c.c_uint,c.c_void_p,c.c_void_p)(proc(b'eglDestroyImageKHR'))(display,image)
    current(display,None,None,None)
    f(egl,'eglDestroyContext',c.c_uint,[c.c_void_p,c.c_void_p])(display,ctx)
    f(egl,'eglDestroySurface',c.c_uint,[c.c_void_p,c.c_void_p])(display,surf)
    f(egl,'eglTerminate',c.c_uint,[c.c_void_p])(display)
    return result
