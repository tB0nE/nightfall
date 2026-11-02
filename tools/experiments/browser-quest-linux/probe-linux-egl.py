#!/usr/bin/python3
"""Run INSIDE the guest: tiny offscreen EGL probe, never changes Chrome config."""
import ctypes as c
import json
import os
import signal
import sys
import time

signal.alarm(5)  # Standalone probe must never run indefinitely.
os.environ['EGL_PLATFORM'] = 'surfaceless'
driver = os.environ.get('NIGHTFALL_EGL_DRIVER', 'kgsl')
if driver not in ('kgsl', 'zink'): raise ValueError('Unsupported probe driver')
os.environ['MESA_LOADER_DRIVER_OVERRIDE'] = driver
report = {'requested_driver': driver, 'surface': [32, 32], 'passed': False}
display = surface = context = None
egl = None
try:
    egl = c.CDLL('libEGL.so.1')
    def fn(name, result, args):
        value = getattr(egl, name); value.restype = result; value.argtypes = args; return value
    get_display = fn('eglGetDisplay', c.c_void_p, [c.c_void_p])
    initialize = fn('eglInitialize', c.c_uint, [c.c_void_p, c.POINTER(c.c_int), c.POINTER(c.c_int)])
    bind = fn('eglBindAPI', c.c_uint, [c.c_uint])
    choose = fn('eglChooseConfig', c.c_uint, [c.c_void_p, c.POINTER(c.c_int), c.POINTER(c.c_void_p), c.c_int, c.POINTER(c.c_int)])
    create_surface = fn('eglCreatePbufferSurface', c.c_void_p, [c.c_void_p, c.c_void_p, c.POINTER(c.c_int)])
    create_context = fn('eglCreateContext', c.c_void_p, [c.c_void_p, c.c_void_p, c.c_void_p, c.POINTER(c.c_int)])
    make_current = fn('eglMakeCurrent', c.c_uint, [c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p])
    error = fn('eglGetError', c.c_uint, [])
    major, minor = c.c_int(), c.c_int()
    display = get_display(None)
    if not display or not initialize(display, c.byref(major), c.byref(minor)):
        raise RuntimeError('EGL initialization failed: ' + hex(error()))
    report['egl_version'] = [major.value, minor.value]
    if not bind(0x30A0): raise RuntimeError('Cannot bind OpenGL ES')
    attrs = (c.c_int * 13)(0x3033, 1, 0x3040, 4, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038)
    config, count = c.c_void_p(), c.c_int()
    if not choose(display, attrs, c.byref(config), 1, c.byref(count)) or count.value < 1:
        raise RuntimeError('No GLES2 pbuffer configuration')
    surface = create_surface(display, config, (c.c_int * 5)(0x3057, 32, 0x3056, 32, 0x3038))
    context = create_context(display, config, None, (c.c_int * 3)(0x3098, 2, 0x3038))
    if not surface or not context or not make_current(display, surface, surface, context):
        raise RuntimeError('Cannot create offscreen GLES context: ' + hex(error()))
    gl = c.CDLL('libGLESv2.so.2')
    gl.glGetString.argtypes = [c.c_uint]; gl.glGetString.restype = c.c_char_p
    for name, enum in [('vendor', 0x1F00), ('renderer', 0x1F01), ('version', 0x1F02)]:
        value = gl.glGetString(enum); report[name] = value.decode() if value else ''
    gl.glClearColor.argtypes = [c.c_float] * 4
    gl.glClear.argtypes = [c.c_uint]
    gl.glReadPixels.argtypes = [c.c_int]*4 + [c.c_uint,c.c_uint,c.c_void_p]
    # Compile/link a real GLES2 program and draw moving geometry.
    def glfn(name, result, args):
        value = getattr(gl, name); value.restype = result; value.argtypes = args; return value
    create_shader = glfn('glCreateShader', c.c_uint, [c.c_uint])
    source_shader = glfn('glShaderSource', None, [c.c_uint,c.c_int,c.POINTER(c.c_char_p),c.c_void_p])
    compile_shader = glfn('glCompileShader', None, [c.c_uint])
    shader_status = glfn('glGetShaderiv', None, [c.c_uint,c.c_uint,c.POINTER(c.c_int)])
    shaders = []
    for kind, source in ((0x8B31,b'attribute vec2 pos; uniform float shift; void main(){gl_Position=vec4(pos.x+shift,pos.y,0.,1.);}'),
                         (0x8B30,b'precision mediump float; void main(){gl_FragColor=vec4(1.,0.,0.,1.);}')):
        shader = create_shader(kind)
        text = c.c_char_p(source); source_shader(shader,1,c.byref(text),None); compile_shader(shader)
        status = c.c_int(); shader_status(shader,0x8B81,c.byref(status))
        if not status.value: raise RuntimeError('GLES shader compilation failed')
        shaders.append(shader)
    program = glfn('glCreateProgram',c.c_uint,[])()
    for shader in shaders: glfn('glAttachShader',None,[c.c_uint,c.c_uint])(program,shader)
    glfn('glBindAttribLocation',None,[c.c_uint,c.c_uint,c.c_char_p])(program,0,b'pos')
    glfn('glLinkProgram',None,[c.c_uint])(program)
    status = c.c_int(); glfn('glGetProgramiv',None,[c.c_uint,c.c_uint,c.POINTER(c.c_int)])(program,0x8B82,c.byref(status))
    if not status.value: raise RuntimeError('GLES program link failed')
    glfn('glUseProgram',None,[c.c_uint])(program)
    shift = glfn('glGetUniformLocation',c.c_int,[c.c_uint,c.c_char_p])(program,b'shift')
    vertices = (c.c_float*6)(-.6,-.6,.6,-.6,0.,.6)
    glfn('glVertexAttribPointer',None,[c.c_uint,c.c_int,c.c_uint,c.c_ubyte,c.c_int,c.c_void_p])(0,2,0x1406,0,0,vertices)
    glfn('glEnableVertexAttribArray',None,[c.c_uint])(0)
    glfn('glViewport',None,[c.c_int]*4)(0,0,32,32)
    uniform = glfn('glUniform1f',None,[c.c_int,c.c_float])
    draw = glfn('glDrawArrays',None,[c.c_uint,c.c_int,c.c_int])
    gl_error = glfn('glGetError',c.c_uint,[])
    # Exercise changing frames and GPU synchronization, not only a static clear.
    # This is a correctness test, not a representative browser benchmark.
    started = time.monotonic()
    frames = 120
    mismatches = 0
    checked_frames = 0
    first_bad_frame = None
    pixel = (c.c_ubyte * 4)()
    for frame in range(frames):
        red = (frame % 17) / 16
        green = (frame % 11) / 10
        gl.glClearColor(red, green, .75, 1)
        gl.glClear(0x4000)
        uniform(shift, (frame % 9 - 4) * .02)
        draw(4,0,3)
        gl.glReadPixels(16, 16, 1, 1, 0x1908, 0x1401, pixel)
        triangle_ok = list(pixel) == [255,0,0,255]
        gl.glReadPixels(0, 0, 1, 1, 0x1908, 0x1401, pixel)
        expected = [round(red*255), round(green*255), 191, 255]
        background_ok = all(abs(a-b) <= 2 for a,b in zip(pixel, expected))
        checked_frames += 1
        if not triangle_ok or not background_ok:
            mismatches += 1
            first_bad_frame = frame
            break  # Never keep submitting after corrupt GPU output.
    report['requested_frames'] = frames
    report['frames'] = checked_frames
    report['first_bad_frame'] = first_bad_frame
    report['mismatches'] = mismatches
    report['elapsed_ms'] = round((time.monotonic()-started)*1000, 2)
    report['pixel'] = list(pixel)
    report['gl_error'] = gl_error()
    report['passed'] = checked_frames == frames and mismatches == 0 and report['gl_error'] == 0
    glfn('glDeleteProgram',None,[c.c_uint])(program)
    for shader in shaders: glfn('glDeleteShader',None,[c.c_uint])(shader)
    renderer = report.get('renderer', '').lower()
    report['software_renderer'] = any(name in renderer for name in ('llvmpipe', 'softpipe', 'swiftshader', 'software'))
    report['adreno_renderer'] = 'adreno' in renderer or renderer.startswith('fd7') or renderer.startswith('fd6')
except Exception as exc:
    report['error'] = str(exc)
finally:
    if egl and display:
        try:
            make_current(display, None, None, None)
            if context: fn('eglDestroyContext', c.c_uint, [c.c_void_p,c.c_void_p])(display, context)
            if surface: fn('eglDestroySurface', c.c_uint, [c.c_void_p,c.c_void_p])(display, surface)
            fn('eglTerminate', c.c_uint, [c.c_void_p])(display)
        except Exception: pass
print(json.dumps(report))
