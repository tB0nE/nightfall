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
    (output/'encoder-selection.json').write_text(json.dumps(report,indent=2)+'\n')
    print('XR_ENCODER '+json.dumps(report),flush=True)
    return backend,bridge,icd,values
