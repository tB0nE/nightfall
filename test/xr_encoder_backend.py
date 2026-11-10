"""Host-local Linux XR encoder selection. Never accepts a device from the client."""
import ctypes
import json
import os
from pathlib import Path


def render_devices(sysfs=Path('/sys/class/drm')):
    devices=[]
    for path in sorted(sysfs.glob('renderD*')):
        try:
            vendor=(path/'device/vendor').read_text().strip()
            pci=(path/'device').resolve().name
            devices.append({'node':'/dev/dri/'+path.name,'vendor':vendor,'pci':pci})
        except OSError:
            continue
    return devices


def driver_manifest(backend, directories=None):
    directories=directories or [Path('/usr/share/vulkan/icd.d'),Path('/etc/vulkan/icd.d'),Path('/usr/local/share/vulkan/icd.d')]
    prefix='radeon' if backend=='vaapi' else 'nvidia'
    for directory in directories:
        for suffix in ('_icd.x86_64.json','_icd.json'):
            candidate=directory/(prefix+suffix)
            if candidate.is_file(): return candidate
    raise RuntimeError(f'{backend} Vulkan driver manifest not found; install the host GPU Vulkan driver')


def nvidia_available(devices):
    if not any(device['vendor']=='0x10de' for device in devices): return False
    try:
        ctypes.CDLL('libcuda.so.1');ctypes.CDLL('libnvidia-encode.so.1')
        return True
    except OSError:
        return False


def amd_codecs(bridge, node):
    library=ctypes.CDLL(str(bridge))
    probe=library.meteor_vaapi_codecs_v1
    probe.argtypes=[ctypes.c_char_p];probe.restype=ctypes.c_int
    mask=probe(os.fsencode(node))
    return [codec for bit,codec in [(1,'h264'),(2,'h265')] if mask&bit]


VA_PROFILES={'h264':6,'h265':17}  # VAProfileH264Main, VAProfileHEVCMain
VA_ENCODE_ENTRYPOINTS=(6,8)  # VAEntrypointEncSlice, VAEntrypointEncSliceLP
VA_ATTRIB_MAX_PICTURE_WIDTH,VA_ATTRIB_MAX_PICTURE_HEIGHT=18,19
VA_ATTRIB_NOT_SUPPORTED=0x80000000


def vaapi_max_frame(node, codecs):
    """The largest frame (width, height) every listed codec encodes on node, or None if unknown.

    Both eyes go side by side into one frame, so on GPUs that stop at 4096 (AMD Polaris) the
    headset has to offer smaller eyes. Only reads the driver's limits; never encodes."""
    try:
        va=ctypes.CDLL('libva.so.2');va_drm=ctypes.CDLL('libva-drm.so.2')
    except OSError:
        return None
    class Attrib(ctypes.Structure):
        _fields_=[('type',ctypes.c_int),('value',ctypes.c_uint32)]
    va_drm.vaGetDisplayDRM.argtypes=[ctypes.c_int];va_drm.vaGetDisplayDRM.restype=ctypes.c_void_p
    va.vaInitialize.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_int),ctypes.POINTER(ctypes.c_int)]
    va.vaTerminate.argtypes=[ctypes.c_void_p]
    va.vaGetConfigAttributes.argtypes=[ctypes.c_void_p,ctypes.c_int,ctypes.c_int,ctypes.POINTER(Attrib),ctypes.c_int]
    try:
        fd=os.open(node,os.O_RDWR)
    except OSError:
        return None
    try:
        display=va_drm.vaGetDisplayDRM(fd)
        major,minor=ctypes.c_int(),ctypes.c_int()
        if not display or va.vaInitialize(display,ctypes.byref(major),ctypes.byref(minor))!=0:
            return None
        try:
            limit=None
            for codec in codecs:
                best=None
                for entrypoint in VA_ENCODE_ENTRYPOINTS:
                    attrs=(Attrib*2)(Attrib(VA_ATTRIB_MAX_PICTURE_WIDTH,0),Attrib(VA_ATTRIB_MAX_PICTURE_HEIGHT,0))
                    if va.vaGetConfigAttributes(display,VA_PROFILES[codec],entrypoint,attrs,2)!=0: continue
                    if VA_ATTRIB_NOT_SUPPORTED in (attrs[0].value,attrs[1].value) or not attrs[0].value or not attrs[1].value: continue
                    size=(int(attrs[0].value),int(attrs[1].value))
                    best=size if best is None else (max(best[0],size[0]),max(best[1],size[1]))
                if best is None: return None
                limit=best if limit is None else (min(limit[0],best[0]),min(limit[1],best[1]))
            return limit
        finally:
            va.vaTerminate(display)
    finally:
        os.close(fd)


def select(root, output, environment=None, devices=None):
    env=os.environ if environment is None else environment
    devices=render_devices() if devices is None else devices
    requested=env.get('NIGHTFALL_XR_ENCODER_BACKEND','nvenc')
    if requested not in ('auto','nvenc','vaapi'): raise ValueError('XR encoder must be auto, nvenc or vaapi')
    node=env.get('NIGHTFALL_XR_RENDER_DEVICE')
    if node and requested=='nvenc': raise ValueError('XR render_device is only used with the AMD VA-API backend')
    backend=requested
    if backend=='auto': backend='nvenc' if not node and nvidia_available(devices) else 'vaapi'
    installed=(root/'xr-runtime/manifest.json').is_file()
    package=root/'xr-runtime' if installed else root/'.build-cache/meteor-xr/amd-vaapi'
    values={}
    codecs=['h264','h265']
    max_frame=None
    if backend=='vaapi':
        if installed:
            manifest=json.loads((package/'manifest.json').read_text())
            if 'vaapi' not in manifest.get('backends',[]): raise RuntimeError('This XR runtime does not include the AMD encoder; install the updated Meteor package')
        else:
            from run_meteor_vaapi_probe import require_current_build
            require_current_build()
        from run_meteor_vaapi_probe import require_healthy_boot
        require_healthy_boot(root/'.build-cache/meteor-xr/amd-vaapi/failed-boot.json')
        candidates=[device for device in devices if device['vendor']=='0x1002' and (not node or device['node']==node)]
        if len(candidates)!=1: raise RuntimeError('Select one AMD GPU using xr.render_device = "/dev/dri/renderD…"; available: '+str([d['node'] for d in candidates]))
        device=candidates[0];node=device['node']
        bridge=package/'libmeteor-vaapi-probe.so'
        codecs=amd_codecs(bridge,node) if bridge.is_file() else []
        if not codecs: raise RuntimeError(f'{node} does not provide hardware H.264/HEVC encoding and VA video processing')
        max_frame=vaapi_max_frame(node,codecs)
        if env.get('NIGHTFALL_XR_CAPABILITIES_ONLY')!='1':
            if env.get('NIGHTFALL_XR_CODEC','h264') not in codecs: raise RuntimeError('Selected AMD GPU does not support the requested XR codec')
            if env.get('NIGHTFALL_XR_FOVEATED_ENCODING','0')!='0': raise RuntimeError('AMD XR requires Foveated Encoding Off')
        pci=device['pci']
        if len(pci)!=12 or pci[4]!=':' or pci[7]!=':' or pci[10]!='.' or any(c not in '0123456789abcdefABCDEF:.' for c in pci):
            raise RuntimeError('Cannot identify the selected AMD PCI device')
        values['DRI_PRIME']='pci-'+pci.replace(':','_').replace('.','_')+'!'
        values['NIGHTFALL_XR_RENDER_DEVICE']=node
    else:
        bridge=output/'libmeteor-nvenc-probe.so'
    icd=driver_manifest(backend)
    report={'backend':backend,'requested':requested,'render_device':node,'vulkan_driver':str(icd),
            'codec':env.get('NIGHTFALL_XR_CODEC','h264'),'live_bitrate':backend=='nvenc','foveated_encoding':backend=='nvenc','codecs':codecs}
    if max_frame: report['max_frame']=list(max_frame)
    (output/'encoder-selection.json').write_text(json.dumps(report,indent=2)+'\n')
    print('XR_ENCODER '+json.dumps(report),flush=True)
    return backend,bridge,icd,values
