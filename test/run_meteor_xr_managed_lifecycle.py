"""Opt-in GPU integration: single-session exclusion, cancel, then clean relaunch."""
import json
from pathlib import Path
import signal
import subprocess
import sys
import time


def run(root):
    binary = root / 'meteor/target/release/nightfall-meteor'
    command = [str(binary), '--xr-dev', str(root), '--smoke']
    out = root / '.build-cache/meteor-xr/managed-lifecycle-tests'
    out.mkdir(parents=True, exist_ok=True)
    with (out / 'cancel.log').open('w') as log:
        child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic()+45
            while 'Meteor XR [streaming]' not in (out / 'cancel.log').read_text():
                if child.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Managed session failed before cancellable live frames')
                time.sleep(.05)
            competing = subprocess.run(command, capture_output=True, text=True, timeout=5)
            assert competing.returncode != 0 and 'another managed XR session' in competing.stderr
            child.send_signal(signal.SIGINT)
            assert child.wait(timeout=10) == 0
            status = json.loads((root / '.build-cache/meteor-xr/managed-session/status.json').read_text())
            assert status['state'] == 'cancelled'
        finally:
            if child.poll() is None:
                child.send_signal(signal.SIGTERM)
                child.wait(timeout=10)
    with (out / 'relaunch.log').open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=100)
    status = json.loads((root / '.build-cache/meteor-xr/managed-session/status.json').read_text())
    assert status['state'] == 'completed'
    print('PASS: concurrent session rejected, active session cancelled, clean relaunch validated')


if __name__ == '__main__':
    run(Path(sys.argv[1]).resolve())
