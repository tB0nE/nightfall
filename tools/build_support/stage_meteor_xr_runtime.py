#!/usr/bin/env python3
"""Stage a relocatable Linux NVIDIA/AMD XR runtime for packaging validation.

Build-machine tool only. Does not modify Steam, trust records or running services.
The destination must not exist. Driver/system libraries are not copied.
"""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'test'))
from xr_preflight_cache import valid

BINARIES = (
    '.build-cache/meteor-xr/monado-linux-spike/capture-build/src/xrt/targets/service/monado-service',
    '.build-cache/meteor-xr/monado-linux-spike/capture-build/src/xrt/targets/openxr/libopenxr_monado.so',
)


def modules(root):
    """Include local imports, including imports inside diagnostic branches."""
    pending = [root / 'test/run_monado_nvenc_spike.py', root / 'test/xr_local_application.py',
               root / 'test/xr_launch_intent.py']
    found = set()
    while pending:
        path = pending.pop()
        if path in found:
            continue
        found.add(path)
        for node in ast.walk(ast.parse(path.read_text())):
            names = ([node.module] if isinstance(node, ast.ImportFrom) else
                     [item.name for item in node.names] if isinstance(node, ast.Import) else [])
            for name in names:
                if name:
                    candidate = root / 'test' / (name.split('.')[0] + '.py')
                    if candidate.is_file():
                        pending.append(candidate)
    return found


def stage(root, destination, helpers, system_libraries=(), xrizer=None, vaapi=None):
    manifest = json.loads((helpers / 'validated.json').read_text())
    if not isinstance(manifest, dict) or not isinstance(manifest.get('key'), str):
        raise ValueError('Invalid validated XR helper manifest')
    if not valid(helpers, manifest.get('key')):
        raise ValueError('XR helpers must come from an intact validated build cache')
    paths = modules(root) | {root / name for name in BINARIES} | {
        root / 'tools/meteor_xr_runtime.py', root / 'tools/meteor_xr_install.py', root / 'tools/meteor_xr.py',
        root / 'tools/meteor_vr_library.py', root / 'LICENSE',
    }
    for source in paths:
        if not source.is_file():
            raise ValueError(f'Missing XR packaging input: {source}')
    destination.mkdir(mode=0o700)  # Refuse to overwrite a previous package.
    checksums = {}
    for source in sorted(paths):
        relative = source.relative_to(root)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        checksums[str(relative)] = hashlib.sha256(target.read_bytes()).hexdigest()
    package = destination / 'xr-runtime'
    package.mkdir()
    if xrizer is not None:
        xrizer = Path(xrizer)
        for name in ('bin/linux64/vrclient.so', 'bin/version.txt', 'LICENSE',
                     'DEPENDENCY_NOTICES.txt', 'UPSTREAM_REVISION', 'SOURCE_URL', 'Cargo.lock'):
            source = xrizer / name
            if not source.is_file():
                raise ValueError(f'Missing xrizer packaging input: {source}')
            target = package / 'xrizer' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            checksums[str(target.relative_to(destination))] = hashlib.sha256(target.read_bytes()).hexdigest()
    for name in ('libmeteor-tracking-probe.so', 'libmeteor-nvenc-probe.so'):
        shutil.copy2(helpers / name, package / name)
        checksums['xr-runtime/' + name] = hashlib.sha256((package / name).read_bytes()).hexdigest()
    if vaapi is not None:
        source=Path(vaapi)
        if not source.is_file(): raise ValueError('Missing AMD VA-API encoder bridge')
        target=package/'libmeteor-vaapi-probe.so'
        shutil.copy2(source,target)
        checksums[str(target.relative_to(destination))]=hashlib.sha256(target.read_bytes()).hexdigest()
    notice_root = root / '.build-cache/meteor-xr/monado-linux-spike/capture-source'
    notices = [notice_root / 'LICENSE', *sorted((notice_root / 'LICENSES').glob('*.txt')),
               notice_root / 'src/external/cjson/cjson/LICENSE']
    for source in notices:
        if not source.is_file():
            raise ValueError(f'Missing runtime license input: {source}')
        relative = source.relative_to(notice_root)
        target = package / 'notices/monado' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        checksums[str(target.relative_to(destination))] = hashlib.sha256(target.read_bytes()).hexdigest()
    copyright_lines = set()
    for source in notice_root.rglob('*'):
        if source.is_file() and source.suffix in ('.c', '.cpp', '.h', '.hpp'):
            for line in source.read_text(errors='replace').splitlines()[:90]:
                if 'copyright' in line.lower() or 'SPDX-FileCopyrightText:' in line:
                    copyright_lines.add(line.strip().lstrip('/* ').rstrip('*/ '))
    copyright_notice = package / 'notices/monado/SOURCE-COPYRIGHTS.txt'
    copyright_notice.write_text('\n'.join(sorted(copyright_lines))+'\n')
    checksums[str(copyright_notice.relative_to(destination))] = hashlib.sha256(copyright_notice.read_bytes()).hexdigest()
    headers = root / '.build-cache/meteor-xr/WiVRn/external/ffnvcodec'
    for source in sorted(headers.glob('*.h')):
        text = source.read_text().split('*/', 1)[0] + '*/\n'
        if 'Permission is hereby granted' not in text:
            raise ValueError(f'Missing codec header license: {source.name}')
        target = package / 'notices/ffnvcodec' / (source.name + '.license.txt')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        checksums[str(target.relative_to(destination))] = hashlib.sha256(target.read_bytes()).hexdigest()
    build_notices = root / '.build-cache/meteor-xr/build-notices'
    for source in sorted(build_notices.glob('*.txt')):
        target = package / 'notices/build-dependencies' / source.name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        checksums[str(target.relative_to(destination))] = hashlib.sha256(target.read_bytes()).hexdigest()
    for source in system_libraries:
        source = Path(source)
        # Never gather arbitrary GPU/OS libraries from the build host.
        allowed=source.name in ('libcjson.so.1','libavcodec.so.62','libavutil.so.60','libswscale.so.9') or source.name.startswith('libdav1d.so.')
        if not allowed:
            raise ValueError('Only explicit cJSON/FFmpeg/dav1d private dependencies may be bundled')
        target = package / ('lib' if source.name=='libcjson.so.1' else 'encoder-lib') / source.name
        target.parent.mkdir(exist_ok=True)
        shutil.copy2(source, target)
        checksums[str(target.relative_to(destination))] = hashlib.sha256(target.read_bytes()).hexdigest()
    notice = package / 'THIRD_PARTY_NOTICES.txt'
    notice.write_text('Meteor managed XR runtime\n'
        'Nightfall supervisor and bridges: GNU GPL v3; see the root LICENSE.\n'
        'Monado by Collabora and contributors: Boost Software License 1.0 and per-file licenses.\n'
        'Original Monado license texts and the cJSON MIT notice are included in notices/monado.\n'
        'NVIDIA/ffnvcodec header licenses, when available, are retained in notices/ffnvcodec.\n'
        'Baseline dependency copyright files, when available, are in notices/build-dependencies.\n'
        'Upstream: https://gitlab.freedesktop.org/monado/monado\n'
        'Nightfall build hooks and patches: test/monado_*.patch in the Nightfall source repository.\n'
        'FFmpeg 8 LGPLv2.1 and dav1d BSD notices are included when their encoder runtime is bundled.\n'
        'GPU drivers, libva/DRM, Vulkan loader, libudev and host C/C++ runtimes are not bundled here.\n'
        'A complete compiled-component attribution audit remains required before distribution.\n')
    checksums[str(notice.relative_to(destination))] = hashlib.sha256(notice.read_bytes()).hexdigest()
    (package / 'manifest.json').write_text(json.dumps({
        'version': 1, 'backend': 'linux-gpu' if vaapi else 'nvidia',
        'backends': ['nvenc','vaapi'] if vaapi else ['nvenc'], 'helper_build': manifest['key'],
        'openvr_compat': 'xr-runtime/xrizer' if xrizer is not None else None,
        'sha256': checksums,
    }, indent=2) + '\n')
    cache = destination / '.build-cache/meteor-xr'
    cache.mkdir(parents=True, exist_ok=True)
    # Fresh local configuration; never copy developer paths, keys or session data.
    (cache / 'application.json').write_text(json.dumps({
        'argv': ['/usr/bin/false'], 'cwd': '/', 'launch': 'steam',
        'steam_app_id': '*', 'steam_runtime': True,
    }, indent=2) + '\n')
    print(f'Staged XR runtime: {destination}')
    print('Not yet a release package: system-library audit and third-party notices remain required.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--helpers', required=True, type=Path,
                        help='Validated helper-cache directory produced on the build machine')
    parser.add_argument('--library', action='append', type=Path, default=[],
                        help='Explicit baseline-built libcjson.so.1 to include')
    parser.add_argument('--xrizer', type=Path, help='Independently built xrizer runtime and notices')
    args = parser.parse_args()
    stage(ROOT, args.destination.resolve(), args.helpers.resolve(), args.library, args.xrizer)


if __name__ == '__main__':
    main()
