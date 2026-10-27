#!/usr/bin/env python3
"""Launch installed XR game support without source checkout checks or compilation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).absolute().parents[1]
sys.path.insert(0, str(ROOT / 'test'))
BRIDGES = ('libmeteor-tracking-probe.so', 'libmeteor-nvenc-probe.so')


def validate(root):
    package = root / 'xr-runtime'
    manifest = json.loads((package / 'manifest.json').read_text())
    if not isinstance(manifest, dict):
        raise ValueError('Invalid installed XR manifest')
    if manifest.get('version') != 1 or manifest.get('backend') not in ('nvidia','linux-gpu'):
        raise ValueError('Unsupported installed XR runtime manifest')
    backends=manifest.get('backends',['nvenc'])
    if backends not in (['nvenc'],['nvenc','vaapi']): raise ValueError('Invalid XR encoder backend list')
    # Hashes detect incomplete/corrupt packaging; they are not a signing scheme.
    entries = manifest.get('sha256')
    if not isinstance(entries, dict):
        raise ValueError('Missing installed XR checksums')
    required = [
        'xr-runtime/' + name for name in BRIDGES
    ] + [
        '.build-cache/meteor-xr/monado-linux-spike/capture-build/src/xrt/targets/service/monado-service',
        '.build-cache/meteor-xr/monado-linux-spike/capture-build/src/xrt/targets/openxr/libopenxr_monado.so',
        'test/run_monado_nvenc_spike.py',
        'tools/meteor_xr_runtime.py', 'tools/meteor_xr_install.py',
        'tools/meteor_xr.py', 'tools/meteor_vr_library.py', 'LICENSE',
    ]
    if 'vaapi' in backends:
        required += ['xr-runtime/libmeteor-vaapi-probe.so','test/xr_encoder_backend.py',
                     'xr-runtime/encoder-lib/libavcodec.so.62','xr-runtime/encoder-lib/libavutil.so.60']
    if any(name not in entries for name in required):
        raise ValueError('Incomplete installed XR runtime manifest')
    if manifest.get('openvr_compat') is not None:
        if manifest['openvr_compat'] != 'xr-runtime/xrizer' or any(
                'xr-runtime/xrizer/' + name not in entries for name in (
                    'bin/linux64/vrclient.so', 'LICENSE', 'DEPENDENCY_NOTICES.txt', 'UPSTREAM_REVISION')):
            raise ValueError('Incomplete bundled xrizer runtime manifest')
    for name, expected in entries.items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Invalid installed XR runtime path')
        source = root / relative
        if not isinstance(expected, str) or hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise ValueError(f'Installed XR runtime checksum mismatch: {name}')
    return manifest


def prepare(root, output):
    manifest=validate(root)
    package = root / 'xr-runtime'
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name in BRIDGES + (('libmeteor-vaapi-probe.so',) if 'vaapi' in manifest.get('backends',[]) else ()):
        shutil.copy2(package / name, output / name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capabilities',action='store_true',help='Query local encoder capabilities without starting XR')
    parser.add_argument('--check', action='store_true', help='Validate files without starting XR')
    args = parser.parse_args()
    if args.check:
        import tempfile
        with tempfile.TemporaryDirectory(prefix='meteor-xr-check-') as directory:
            prepare(ROOT, Path(directory))
        print('Installed XR runtime files verified (GPU drivers and gameplay not tested).')
        return
    if args.capabilities:
        import tempfile
        validate(ROOT)
        os.environ['METEOR_XR_FFMPEG_LIBDIR']=str(ROOT/'xr-runtime/encoder-lib')
        from xr_encoder_backend import select
        env=dict(os.environ,NIGHTFALL_XR_CAPABILITIES_ONLY='1')
        with tempfile.TemporaryDirectory(prefix='meteor-xr-cap-') as temporary:
            directory=Path(temporary)
            select(ROOT,directory,env)
            print((directory/'encoder-selection.json').read_text().replace('\n',''))
        return
    if not os.environ.get('NIGHTFALL_XR_APPLICATION_SPEC'):
        raise ValueError('Installed XR runtime requires a host-local application specification')
    output = Path(os.environ['NIGHTFALL_XR_PROBE_OUTPUT'])
    prepare(ROOT, output)
    libraries = ROOT / 'xr-runtime/lib'
    if libraries.is_dir():
        os.environ['LD_LIBRARY_PATH'] = str(libraries) + (
            ':' + os.environ['LD_LIBRARY_PATH'] if os.environ.get('LD_LIBRARY_PATH') else '')
    encoder_libraries=ROOT/'xr-runtime/encoder-lib'
    if encoder_libraries.is_dir():
        os.environ['METEOR_XR_FFMPEG_LIBDIR']=str(encoder_libraries)
    from run_monado_nvenc_spike import run
    run(ROOT, output)


if __name__ == '__main__':
    main()
