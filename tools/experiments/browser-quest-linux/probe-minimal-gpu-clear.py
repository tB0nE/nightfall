#!/usr/bin/python3
"""Guest-only EGL clear: no X11, Chrome, decoder, imports or shared buffers."""
import argparse
import ctypes as c
import json
import os
import signal
import time
parser=argparse.ArgumentParser();parser.add_argument('--draw',action='store_true');parser.add_argument('--diagnostics',action='store_true');parser.add_argument('--no-early-preamble',action='store_true');parser.add_argument('--no-preamble',action='store_true');parser.add_argument('--arithmetic-vertex',action='store_true');args=parser.parse_args()
if args.diagnostics:
    args.draw=True
    os.environ['IR3_SHADER_DEBUG']='vs,fs,disasm,nocache'
if args.no_early_preamble:
    os.environ['IR3_SHADER_DEBUG']=os.environ.get('IR3_SHADER_DEBUG','nocache')+',noearlypreamble'
if args.no_preamble:
    os.environ['IR3_SHADER_DEBUG']=os.environ.get('IR3_SHADER_DEBUG','nocache')+',nopreamble,noearlypreamble'
signal.alarm(4)
report={'passed':False,'surface':[32,32],'operation':'private_pbuffer_clear_readback','external_buffers':False,'early_preamble_disabled':args.no_early_preamble or args.no_preamble,'preamble_optimization_disabled':args.no_preamble}
egl=None;display=surface=context=None

def fn(lib,name,result,args):
    f=getattr(lib,name);f.restype=result;f.argtypes=args;return f

try:
    egl=c.CDLL('libEGL.so.1');gl=c.CDLL('libGLESv2.so.2')
    display=fn(egl,'eglGetDisplay',c.c_void_p,[c.c_void_p])(None)
    major=c.c_int();minor=c.c_int()
    if not fn(egl,'eglInitialize',c.c_uint,[c.c_void_p,c.POINTER(c.c_int),c.POINTER(c.c_int)])(display,c.byref(major),c.byref(minor)):raise RuntimeError('eglInitialize')
    if not fn(egl,'eglBindAPI',c.c_uint,[c.c_uint])(0x30a0):raise RuntimeError('eglBindAPI')
    config=c.c_void_p();count=c.c_int()
    attrs=(c.c_int*13)(0x3033,1,0x3040,0x40,0x3024,8,0x3023,8,0x3022,8,0x3021,8,0x3038)
    if not fn(egl,'eglChooseConfig',c.c_uint,[c.c_void_p,c.POINTER(c.c_int),c.POINTER(c.c_void_p),c.c_int,c.POINTER(c.c_int)])(display,attrs,c.byref(config),1,c.byref(count)) or not count.value:raise RuntimeError('eglChooseConfig')
    surface=fn(egl,'eglCreatePbufferSurface',c.c_void_p,[c.c_void_p,c.c_void_p,c.POINTER(c.c_int)])(display,config,(c.c_int*5)(0x3057,32,0x3056,32,0x3038))
    context=fn(egl,'eglCreateContext',c.c_void_p,[c.c_void_p,c.c_void_p,c.c_void_p,c.POINTER(c.c_int)])(display,config,None,(c.c_int*3)(0x3098,3,0x3038))
    current=fn(egl,'eglMakeCurrent',c.c_uint,[c.c_void_p]*4)
    if not context or not surface or not current(display,surface,surface,context):raise RuntimeError('eglMakeCurrent')
    renderer=fn(gl,'glGetString',c.c_char_p,[c.c_uint])(0x1f01).decode()
    report['renderer']=renderer
    if not renderer.startswith(('FD7','FD6')):raise RuntimeError('Expected hardware Freedreno renderer')
    clear_color=fn(gl,'glClearColor',None,[c.c_float]*4)
    clear=fn(gl,'glClear',None,[c.c_uint])
    read=fn(gl,'glReadPixels',None,[c.c_int]*4+[c.c_uint,c.c_uint,c.c_void_p])
    error=fn(gl,'glGetError',c.c_uint,[])
    if args.draw:
        report['operation']='private_pbuffer_triangle_readback'
        shaders=[]
        sources=[(0x8b31,b'#version 300 es\nvoid main(){vec2 p[3]=vec2[3](vec2(-.7,-.7),vec2(.7,-.7),vec2(0.,.7));gl_Position=vec4(p[gl_VertexID],0.,1.);}'),(0x8b30,b'#version 300 es\nprecision mediump float;out vec4 color;void main(){color=vec4(1.,0.,0.,1.);}')]
        if args.arithmetic_vertex:
            sources[0]=(0x8b31,b'#version 300 es\nvoid main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4((p-vec2(.5))*.75,0.,1.);}')
            report['vertex_mode']='arithmetic'
        for kind,text in sources:
            shader=fn(gl,'glCreateShader',c.c_uint,[c.c_uint])(kind)
            source=c.c_char_p(text)
            fn(gl,'glShaderSource',None,[c.c_uint,c.c_int,c.POINTER(c.c_char_p),c.c_void_p])(shader,1,c.byref(source),None)
            fn(gl,'glCompileShader',None,[c.c_uint])(shader)
            ok=c.c_int();fn(gl,'glGetShaderiv',None,[c.c_uint,c.c_uint,c.POINTER(c.c_int)])(shader,0x8b81,c.byref(ok))
            if not ok.value:raise RuntimeError('Triangle shader compilation failed')
            shaders.append(shader)
        program=fn(gl,'glCreateProgram',c.c_uint,[])()
        for shader in shaders:fn(gl,'glAttachShader',None,[c.c_uint,c.c_uint])(program,shader)
        fn(gl,'glLinkProgram',None,[c.c_uint])(program)
        ok=c.c_int();fn(gl,'glGetProgramiv',None,[c.c_uint,c.c_uint,c.POINTER(c.c_int)])(program,0x8b82,c.byref(ok))
        if not ok.value:raise RuntimeError('Triangle shader link failed')
        fn(gl,'glUseProgram',None,[c.c_uint])(program)
        fn(gl,'glViewport',None,[c.c_int]*4)(0,0,32,32)
        draw=fn(gl,'glDrawArrays',None,[c.c_uint,c.c_int,c.c_int])
    pixel=(c.c_ubyte*4)();frames=0;started=time.monotonic()
    for frame in range(1 if args.diagnostics else 120):
        red=(frame%17)/16;green=(frame%11)/10
        clear_color(red,green,.75,1);clear(0x4000)
        if args.draw:
            draw(4,0,3);read(16,16,1,1,0x1908,0x1401,pixel)
            if list(pixel)!=[255,0,0,255]:
                report.update(first_bad_frame=frame,checked_frames=frames,triangle_pixel=list(pixel),gl_error=error())
                raise RuntimeError('Triangle centre mismatch')
        read(0,0,1,1,0x1908,0x1401,pixel)
        if error() or any(abs(a-b)>2 for a,b in zip(pixel,[round(red*255),round(green*255),191,255])):raise RuntimeError('Clear/readback mismatch')
        frames+=1
        time.sleep(max(0,started+frames/60-time.monotonic()))
    report.update(passed=True,frames=frames,elapsed_s=round(time.monotonic()-started,3))
except Exception as error:
    report.update(error=type(error).__name__+': '+str(error))
finally:
    if egl and display:
        try:
            fn(egl,'eglMakeCurrent',c.c_uint,[c.c_void_p]*4)(display,None,None,None)
            if surface:fn(egl,'eglDestroySurface',c.c_uint,[c.c_void_p,c.c_void_p])(display,surface)
            if context:fn(egl,'eglDestroyContext',c.c_uint,[c.c_void_p,c.c_void_p])(display,context)
            fn(egl,'eglTerminate',c.c_uint,[c.c_void_p])(display)
        except Exception:pass
print(json.dumps(report),flush=True)
