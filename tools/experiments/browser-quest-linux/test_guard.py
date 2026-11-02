#!/usr/bin/python3
"""Bound automated headset tests on-device, including host-crash/USB-loss cleanup."""
import os
from pathlib import Path
import shlex
import signal
import subprocess
import uuid

SCRIPT = '/data/local/tmp/nightfall-browser-test-watchdog.sh'
LEASE = '/data/local/tmp/nightfall-browser-test.lease'


class HeadsetTestGuard:
    def __init__(self, seconds):
        if not isinstance(seconds, int) or not 1 <= seconds <= 150:
            raise ValueError('Headset tests require a 1–150 second watchdog')
        self.seconds = seconds
        self.adb = os.environ.get('ADB', 'adb')
        self.token = uuid.uuid4().hex
        self.armed = False
        self.serial = None
        self.previous_term = None

    def shell(self, command, **kwargs):
        return subprocess.run([self.adb, '-s', self.serial, 'shell', command], timeout=8, check=True,
                              capture_output=True, **kwargs)

    def __enter__(self):
        self.serial = subprocess.check_output([self.adb, 'get-serialno'], timeout=5, text=True).strip()
        if not self.serial or self.serial == 'unknown':
            raise RuntimeError('No unique headset available to arm the watchdog')
        script = Path(__file__).with_name('test-watchdog.sh').read_bytes()
        self.shell('cat > ' + shlex.quote(SCRIPT), input=script)
        # A new token supersedes an earlier watchdog; its delayed cleanup can
        # never stop this newer run. Coordinate agents rather than overlap tests.
        command = 'printf %s ' + shlex.quote(self.token) + ' > ' + shlex.quote(LEASE)
        self.shell(command)
        self.armed = True
        try:
            self.shell('nohup sh ' + shlex.quote(SCRIPT) + ' wait ' + str(self.seconds) + ' ' + self.token
                       + ' > /data/local/tmp/nightfall-browser-test-watchdog.log 2>&1 < /dev/null &')
        except BaseException:
            self.cleanup()
            raise
        self.previous_term = signal.getsignal(signal.SIGTERM)
        signal.signal(signal.SIGTERM, self.terminate)
        return self

    def terminate(self, signum, frame):
        raise SystemExit(128 + signum)

    def cleanup(self):
        if not self.armed:
            return
        try:
            self.shell('sh ' + shlex.quote(SCRIPT) + ' cleanup 0 ' + self.token)
        except (OSError, subprocess.SubprocessError):
            print('USB cleanup unavailable; the on-device test watchdog remains armed.', flush=True)
        self.armed = False

    def __exit__(self, kind, value, traceback):
        try:
            self.cleanup()
        finally:
            if self.previous_term is not None:
                signal.signal(signal.SIGTERM, self.previous_term)
        return False
