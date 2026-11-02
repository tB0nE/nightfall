#!/usr/bin/python3
"""Bounded offscreen EGL driver comparison with the isolated KGSL ABI adapter, with automatic device cleanup.
Requires the rebuilt companion installed and the NDK-built static probe binary.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import time
from test_guard import HeadsetTestGuard

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--include-zink', action='store_true', help='Also retest the previously device-lost Vulkan path')
    args = parser.parse_args()
    binary = ROOT / '.build-cache/browser-quest-linux/kgsl-probe/libnightfall-kgsl-compat.so'
    if not binary.is_file(): raise RuntimeError('Compile kgsl-compat.c with NDK r29 first')
    result = {'limits': '32x32 offscreen EGL only; five seconds per driver; no Chrome or video.'}
    output = ROOT / '.build-cache/browser-quest-linux' / ('egl-compat-' + time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '.json')
    with HeadsetTestGuard(20) as guard:
        # Nothing in this test needs a worn/awake override or media playback.
        guard.shell('am force-stop app.nightfall.browserlab')
        for source, name in ((binary, 'libnightfall-kgsl-compat.so'),
                             (ROOT / 'tools/experiments/browser-quest-linux/probe-linux-egl.py', 'probe-linux-egl.py')):
            target = 'files/linux/rootfs/tmp/' + name
            guard.shell('run-as app.nightfall.browserlab sh -c ' + shlex.quote('cat > ' + target), input=source.read_bytes())
            guard.shell('run-as app.nightfall.browserlab chmod 700 ' + target)
        guard.shell('run-as app.nightfall.browserlab rm -f files/linux/gpu-allocation-status.json')
        guard.shell('run-as app.nightfall.browserlab am start-foreground-service --user 0 -n app.nightfall.browserlab/.GpuAllocationService --ez egl_probe true' + (' --ez include_zink true' if args.include_zink else ''))
        deadline = time.monotonic() + 13
        while time.monotonic() < deadline:
            try:
                status = json.loads(guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-allocation-status.json').stdout)
                if status.get('complete'):
                    result['status'] = status
                    break
            except (ValueError, subprocess.SubprocessError): pass
            time.sleep(.2)
        else: raise TimeoutError('Allocation service did not finish before bounded deadline')
        for mode in (('kgsl', 'zink') if args.include_zink else ('kgsl',)):
            raw = guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-allocation-' + mode + '.json').stdout.decode()
            reports = []
            for line in raw.splitlines():
                try:
                    value = json.loads(line)
                    if isinstance(value, dict): reports.append(value)
                except ValueError: pass
            result[mode] = reports[-1] if reports else {'passed': False}
            result[mode]['diagnostics'] = raw[-5000:]
            result[mode]['device_lost'] = 'DEVICE LOST' in raw.upper()
            result[mode]['submission_error'] = 'submit failed' in raw.lower()
            result[mode]['reliable_candidate'] = bool(result[mode].get('passed')
                    and not result[mode].get('software_renderer', True)
                    and not result[mode]['device_lost']
                    and not result[mode]['submission_error']
                    and result['status'].get(mode + '_exit') == 0)
        output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'output': str(output), **result}, indent=2))


if __name__ == '__main__': main()
