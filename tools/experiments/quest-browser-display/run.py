#!/usr/bin/python3
"""Run ordinary-app Quest Browser display tests; no root, capture grants or DRM access."""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
PACKAGE = 'app.nightfall.browserdisplayprobe'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('private', 'public', 'self'), default='private')
    parser.add_argument('--component', choices=(
        'com.oculus.browser.OculusLauncherActivity',
        'org.chromium.chrome.browser.ChromeTabbedActivity',
        'com.oculus.browser.BrowserActivity'), default='com.oculus.browser.OculusLauncherActivity')
    args = parser.parse_args()
    adb = os.environ.get('ADB', 'adb')
    token = str(uuid.uuid4())
    label = args.mode + '-' + ('DisplayControlActivity' if args.mode == 'self' else args.component.rsplit('.', 1)[-1])
    folder = ROOT / '.build-cache/quest-browser-display/results' / (
        datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + label)
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run([adb, 'shell', 'am', 'start', '-n', PACKAGE + '/.BrowserDisplayProbe',
                    '--es', 'mode', args.mode, '--es', 'component', args.component,
                    '--es', 'run_id', token], check=True, timeout=10)
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        try:
            process = subprocess.run([adb, 'shell', 'run-as', PACKAGE, 'cat', 'files/probe.json'],
                                     capture_output=True, text=True, timeout=4)
            data = json.loads(process.stdout)
            if data.get('run_id') == token:
                (folder / 'summary.json').write_text(json.dumps(data, indent=2) + '\n')
                if data.get('complete'):
                    print(json.dumps({'summary': str(folder / 'summary.json'),
                                      'launch_allowed': data.get('launch_allowed'),
                                      'launch_error': data.get('launch_error'),
                                      'control': data.get('control'),
                                      'browser': data.get('browser'),
                                      'end_reason': data.get('end_reason')}, indent=2))
                    return
        except (ValueError, subprocess.SubprocessError):
            pass
        time.sleep(.5)
    raise RuntimeError('Probe did not finish; inspect headset focus and saved summary')


if __name__ == '__main__':
    main()
