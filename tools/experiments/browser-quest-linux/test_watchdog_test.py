#!/usr/bin/python3
"""Exercise the real watchdog shell script using fake Android commands only."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from test_guard import HeadsetTestGuard

SCRIPT = Path(__file__).with_name('test-watchdog.sh')
TOKEN = 'a' * 32
NEW_TOKEN = 'b' * 32


class WatchdogTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nightfall watchdog ')
        self.root = Path(self.temp.name)
        bin_dir = self.root / 'bin'; bin_dir.mkdir()
        for name in ('am', 'setprop'):
            path = bin_dir / name
            path.write_text('#!/bin/sh\nprintf "%s\\n" "' + name + ' $*" >> "$NIGHTFALL_WATCHDOG_ROOT/actions"\n')
            path.chmod(0o700)
        self.env = {**os.environ, 'PATH': str(bin_dir) + ':' + os.environ['PATH'], 'NIGHTFALL_WATCHDOG_ROOT': str(self.root)}
        self.lease = self.root / 'nightfall-browser-test.lease'
        self.lease.write_text(TOKEN)

    def tearDown(self): self.temp.cleanup()

    def run_script(self, mode, seconds, token=TOKEN):
        return subprocess.run(['/bin/sh', str(SCRIPT), mode, str(seconds), token], env=self.env, capture_output=True, timeout=4)

    def actions(self):
        p = self.root / 'actions'
        return p.read_text().splitlines() if p.exists() else []

    def test_cleanup_stops_only_test_apps_and_restores_wake(self):
        self.assertEqual(self.run_script('cleanup', 0).returncode, 0)
        self.assertEqual(self.actions(), ['am force-stop app.nightfall.browserlab',
                         'am force-stop app.nightfall.quest',
                         'am broadcast -a com.oculus.vrpowermanager.automation_disable',
                         'setprop debug.oculus.guardian_pause '])
        self.assertFalse(self.lease.exists())

    def test_deadline_runs_without_a_host_cleanup(self):
        self.assertEqual(self.run_script('wait', 1).returncode, 0)
        self.assertEqual(len(self.actions()), 4)
        self.assertFalse(self.lease.exists())

    def test_old_timer_cannot_stop_a_new_session(self):
        self.lease.write_text(NEW_TOKEN)
        self.assertEqual(self.run_script('cleanup', 0).returncode, 0)
        self.assertEqual(self.actions(), [])
        self.assertEqual(self.lease.read_text(), NEW_TOKEN)

    def test_invalid_bounds_or_token_never_stop_apps(self):
        for seconds in (0, 151): self.assertNotEqual(self.run_script('wait', seconds).returncode, 0)
        self.assertNotEqual(self.run_script('cleanup', 0, 'invalid').returncode, 0)
        self.assertEqual(self.actions(), [])
        for seconds in (0, 151, -1):
            with self.assertRaises(ValueError): HeadsetTestGuard(seconds)


if __name__ == '__main__': unittest.main()
