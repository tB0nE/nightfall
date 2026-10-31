#!/usr/bin/python3
"""Bounded native browser lab liveness/process-count check; no account inspection."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=int, default=420)
parser.add_argument('--interval', type=int, default=15)
args = parser.parse_args()
if args.seconds < 1 or args.interval < 1:
    parser.error('Durations must be positive')
adb = os.environ.get('ADB', 'adb')
package = 'app.nightfall.browserlab'
output = Path(__file__).resolve().parents[3] / '.build-cache/browser-quest-linux/stability-summary.json'
output.parent.mkdir(parents=True, exist_ok=True)


def shell(*command):
    return subprocess.check_output([adb, 'shell', *command], text=True, timeout=10).strip()


app_pid = int(shell('pidof', package))
initial_root = None
samples = []
started = time.monotonic()
while True:
    sample = {'elapsed_s': round(time.monotonic() - started, 1)}
    try:
        rows = [line.split(maxsplit=3) for line in shell('ps', '-A', '-o', 'UID,PID,PPID,NAME').splitlines()[1:]]
        uid = next(row[0] for row in rows if int(row[1]) == app_pid)
        owned = [row for row in rows if row[0] == uid]
        roots = [int(row[1]) for row in owned if int(row[2]) == app_pid and row[3] == 'proot']
        if initial_root is None and roots:
            initial_root = roots[0]
        sample['app_children'] = len(owned) - 1
        sample['root_tracer_alive'] = initial_root is not None and any(int(row[1]) == initial_root for row in owned)
        with urllib.request.urlopen('http://127.0.0.1:6082/lab.html', timeout=5) as response:
            sample['http_status'] = response.status
    except Exception as error:
        sample['error'] = str(error)
    samples.append(sample)
    healthy = all(s.get('root_tracer_alive') and s.get('http_status') == 200 for s in samples)
    result = {'complete': sample['elapsed_s'] >= args.seconds, 'healthy_so_far': healthy,
              'duration_s': sample['elapsed_s'], 'app_pid': app_pid, 'root_tracer_pid': initial_root,
              'max_app_children': max(s.get('app_children', 0) for s in samples), 'samples': samples,
              'limits': 'Liveness check only; inspect video counters separately. No Netflix session inspected.'}
    output.write_text(json.dumps(result, indent=2) + '\n')
    if not healthy or result['complete']:
        print(json.dumps({k: v for k, v in result.items() if k != 'samples'}))
        raise SystemExit(0 if healthy else 1)
    time.sleep(min(args.interval, max(.1, args.seconds - (time.monotonic() - started))))
