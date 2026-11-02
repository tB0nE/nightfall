#!/usr/bin/python3
"""Allocation-only app/native vs PRoot comparison, with automatic device cleanup.
Requires the rebuilt companion installed and the NDK-built static probe binary.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import time
from test_guard import HeadsetTestGuard

ROOT = Path(__file__).resolve().parents[3]


def main():
    binary = ROOT / '.build-cache/browser-quest-linux/kgsl-probe/kgsl-allocation-probe'
    if not binary.is_file(): raise RuntimeError('Compile kgsl-allocation-probe.c with NDK r29 first')
    result = {'limits': '4 KB allocation/free only; not a graphics, video or performance test.'}
    output = ROOT / '.build-cache/browser-quest-linux' / ('kgsl-allocations-' + time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '.json')
    with HeadsetTestGuard(20) as guard:
        # Nothing in this test needs a worn/awake override or media playback.
        guard.shell('am force-stop app.nightfall.browserlab')
        for name in ('files/linux/kgsl-allocation-probe', 'files/linux/rootfs/tmp/kgsl-allocation-probe'):
            guard.shell('run-as app.nightfall.browserlab sh -c ' + shlex.quote('cat > ' + name), input=binary.read_bytes())
            guard.shell('run-as app.nightfall.browserlab chmod 700 ' + name)
        guard.shell('run-as app.nightfall.browserlab rm -f files/linux/gpu-allocation-status.json')
        guard.shell('run-as app.nightfall.browserlab am start-foreground-service --user 0 -n app.nightfall.browserlab/.GpuAllocationService')
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
        for mode in ('native', 'proot'):
            raw = guard.shell('run-as app.nightfall.browserlab cat files/linux/gpu-allocation-' + mode + '.json').stdout.decode()
            try: result[mode] = json.loads(raw)
            except ValueError: result[mode] = {'error': 'Probe produced no valid numeric JSON'}
        output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({'output': str(output), **result}, indent=2))


if __name__ == '__main__': main()
