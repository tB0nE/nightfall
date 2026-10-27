#!/usr/bin/env python3
"""Inspect verified XR ELF files without executing them or loading GPU drivers."""
import argparse
import json
from pathlib import Path
import re
import subprocess
from meteor_xr_runtime import validate

# These libraries belong to the host OS/driver stack, not an arbitrary build PC.
HOST_LIBRARIES = {'libc.so.6', 'libm.so.6', 'libdl.so.2', 'libpthread.so.0', 'librt.so.1',
                  'libgcc_s.so.1', 'libstdc++.so.6', 'libudev.so.1', 'libvulkan.so.1',
                  'ld-linux-x86-64.so.2', 'libva.so.2','libva-drm.so.2','libdrm.so.2'}


def version(value):
    return tuple(int(part) for part in value.split('.'))


def inspect(path):
    text = subprocess.check_output(['readelf', '-h', '-d', '-V', str(path)], text=True, stderr=subprocess.STDOUT)
    needed = re.findall(r'\(NEEDED\).*?\[([^\]]+)\]', text)
    soname = re.findall(r'\(SONAME\).*?\[([^\]]+)\]', text)
    search = re.findall(r'\((?:RPATH|RUNPATH)\).*?\[([^\]]+)\]', text)
    glibc = re.findall(r'\bGLIBC_(\d+(?:\.\d+)+)\b', text)
    cxx = re.findall(r'\bGLIBCXX_(\d+(?:\.\d+)+)\b', text)
    return {'needed': needed, 'soname': soname[0] if soname else None, 'search_paths': search,
            'glibc': max(glibc, key=version) if glibc else None,
            'glibcxx': max(cxx, key=version) if cxx else None,
            'x86_64': bool(re.search(r'Machine:\s+Advanced Micro Devices X86-64', text))}


def audit(root, maximum='2.35'):
    manifest = validate(root)
    files = {}
    for name in manifest['sha256']:
        path = root / name
        with path.open('rb') as handle:
            if handle.read(4) != b'\x7fELF': continue
        files[name] = inspect(path)
    provided = {data['soname'] for data in files.values() if data['soname']}
    required = {name for data in files.values() for name in data['needed']}
    glibc = [data['glibc'] for data in files.values() if data['glibc']]
    minimum = max(glibc, key=version) if glibc else None
    missing = sorted(required - provided - HOST_LIBRARIES)
    errors = []
    if not files: errors.append('No ELF runtime components found')
    if minimum and version(minimum) > version(maximum):
        errors.append(f'Runtime requires glibc {minimum}; packaging baseline is {maximum}. Rebuild on the baseline system.')
    if missing: errors.append('Unbundled non-system dependencies: ' + ', '.join(missing))
    for name, data in files.items():
        if not data['x86_64']: errors.append(f'Unexpected ELF architecture: {name}')
        for search in data['search_paths']:
            if any(part and not part.startswith('$ORIGIN') for part in search.split(':')):
                errors.append(f'Non-relocatable library search path in {name}: {search}')
    return {'schema': 1, 'packaging_glibc_baseline': maximum, 'minimum_glibc': minimum,
            'elf_files': files, 'host_libraries': sorted(required & HOST_LIBRARIES),
            'bundle_libraries': sorted(provided), 'missing_bundle_libraries': missing,
            'dynamic_driver_dependencies': ['libcuda.so.1', 'libnvidia-encode.so.1', 'NVIDIA Vulkan ICD', 'AMD Vulkan ICD / host libva Mesa driver'],
            'errors': errors, 'static_audit_passed': not errors,
            'scope': 'Static ELF audit only; does not validate host drivers, Python, licensing completeness or gameplay.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runtime', type=Path)
    parser.add_argument('--max-glibc', default='2.35')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = audit(args.runtime, args.max_glibc)
    text = json.dumps(report, indent=2) + '\n'
    if args.output: args.output.write_text(text)
    print(text, end='')
    raise SystemExit(0 if report['static_audit_passed'] else 1)


if __name__ == '__main__':
    main()
