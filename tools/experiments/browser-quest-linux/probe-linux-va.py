#!/usr/bin/python3
"""Guest VA-API capability enumeration only; no media, account or decode work."""
import ctypes as c
import json
import os
import signal
signal.alarm(5)
r={'initialized':False}
fd=-1; display=None; va=None
try:
    va=c.CDLL('libva.so.2');drm=c.CDLL('libva-drm.so.2')
    drm.vaGetDisplayDRM.argtypes=[c.c_int];drm.vaGetDisplayDRM.restype=c.c_void_p
    va.vaInitialize.argtypes=[c.c_void_p,c.POINTER(c.c_int),c.POINTER(c.c_int)];va.vaInitialize.restype=c.c_int
    va.vaQueryVendorString.argtypes=[c.c_void_p];va.vaQueryVendorString.restype=c.c_char_p
    va.vaMaxNumProfiles.argtypes=[c.c_void_p];va.vaMaxNumProfiles.restype=c.c_int
    va.vaQueryConfigProfiles.argtypes=[c.c_void_p,c.POINTER(c.c_int),c.POINTER(c.c_int)];va.vaQueryConfigProfiles.restype=c.c_int
    va.vaTerminate.argtypes=[c.c_void_p];va.vaTerminate.restype=c.c_int
    fd=os.open('/dev/kgsl-3d0',os.O_RDWR)
    display=drm.vaGetDisplayDRM(fd)
    if not display:raise RuntimeError('No VA display')
    major,minor=c.c_int(),c.c_int()
    status=va.vaInitialize(display,c.byref(major),c.byref(minor));r['initialize_status']=status
    if status!=0:raise RuntimeError('VA initialization failed')
    r['initialized']=True;r['version']=[major.value,minor.value]
    vendor=va.vaQueryVendorString(display);r['vendor']=vendor.decode() if vendor else ''
    maximum=va.vaMaxNumProfiles(display)
    if not 0<maximum<256:raise RuntimeError('Invalid profile count')
    profiles=(c.c_int*maximum)();count=c.c_int()
    r['query_status']=va.vaQueryConfigProfiles(display,profiles,c.byref(count))
    r['profiles']=list(profiles)[:count.value]
    va.vaMaxNumEntrypoints.argtypes=[c.c_void_p];va.vaMaxNumEntrypoints.restype=c.c_int
    va.vaQueryConfigEntrypoints.argtypes=[c.c_void_p,c.c_int,c.POINTER(c.c_int),c.POINTER(c.c_int)];va.vaQueryConfigEntrypoints.restype=c.c_int
    maximum=va.vaMaxNumEntrypoints(display)
    if not 0<maximum<256:raise RuntimeError('Invalid entrypoint count')
    r['entrypoints']={}
    for profile in r['profiles']:
        values=(c.c_int*maximum)();count=c.c_int()
        status=va.vaQueryConfigEntrypoints(display,profile,values,c.byref(count))
        r['entrypoints'][str(profile)]={'status':status,'values':list(values)[:count.value]}

except Exception as e:r['error']=type(e).__name__+': '+str(e)
finally:
    if r['initialized']:va.vaTerminate(display)
    if fd>=0:os.close(fd)
print(json.dumps(r))
