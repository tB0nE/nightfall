import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from xr_application_lifecycle import run_application, valid_completion


class ApplicationLifecycleTests(unittest.TestCase):
    def test_completion_marker_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'completion.json'
            record = dict(run_id='current', state='completion_requested', target=32,
                          encoded_at_request=33)
            marker.write_text(json.dumps(record))
            self.assertTrue(valid_completion(marker, 'current', 32))
            self.assertFalse(valid_completion(marker, 'stale', 32))
            self.assertFalse(valid_completion(marker, 'current', 120))
            for value in (False, 31, '33'):
                marker.write_text(json.dumps(dict(record, encoded_at_request=value)))
                self.assertFalse(valid_completion(marker, 'current', 32))
            marker.write_text('{')
            self.assertFalse(valid_completion(marker, 'current', 32))

    def test_completion_disconnect_overlap_preserves_normal_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / 'service.log'
            log.write_text('')
            marker = root / 'completion.json'
            stop = root / 'stop'
            code = (
                "import pathlib,json,sys,time; root=pathlib.Path(sys.argv[1]); "
                "(root/'completion.json').write_text(json.dumps(dict(run_id='current', "
                "state='completion_requested',target=32,encoded_at_request=33))); "
                "(root/'service.log').write_text('METEOR_TRACKING_DISCONNECTED reason=test\\n'); "
                "time.sleep(.3); print('normal completion')")
            result, interrupted, forced = run_application(
                [sys.executable, '-c', code, str(root)], env=dict(os.environ),
                timeout=2, service_log=log, stop_file=stop, watch_disconnect=True,
                stop_timeout=1, completion_file=marker, completion_token='current',
                completion_target=32)
            self.assertEqual(result.returncode, 0)
            self.assertFalse(interrupted or forced)
            self.assertFalse(stop.exists())

    def run_child(self, code, *, watch=True, timeout=2, stop_timeout=.2):
        with tempfile.TemporaryDirectory(prefix="nf-xr-lifecycle-") as directory:
            root=Path(directory)
            log=root / "service.log"; log.write_text("")
            stop=root / "client-disconnected"
            return run_application([sys.executable,"-c",code,str(log),str(stop)],
                env=dict(os.environ),timeout=timeout,service_log=log,stop_file=stop,
                watch_disconnect=watch,stop_timeout=stop_timeout)

    def test_normal_completion(self):
        result,interrupted,forced=self.run_child("print('completed')")
        self.assertEqual(result.returncode,0)
        self.assertEqual(result.stdout,"completed\n")
        self.assertFalse(interrupted or forced)

    def test_disconnect_requests_graceful_exit(self):
        result,interrupted,forced=self.run_child(
            "import pathlib,sys,time; "
            "pathlib.Path(sys.argv[1]).write_text('METEOR_TRACKING_DISCONNECTED reason=test\\n'); "
            "stop=pathlib.Path(sys.argv[2]);\n"
            "while not stop.exists(): time.sleep(.01)\n"
            "print('graceful interrupted exit')")
        self.assertEqual(result.returncode,0)
        self.assertTrue(interrupted); self.assertFalse(forced)
        self.assertIn("graceful interrupted",result.stdout)

    def test_unresponsive_child_is_terminated(self):
        result,interrupted,forced=self.run_child(
            "import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text("
            "'METEOR_TRACKING_DISCONNECTED reason=test\\n'); time.sleep(30)")
        self.assertTrue(interrupted and forced)
        self.assertNotEqual(result.returncode,0)

    def test_other_failures_remain_failures(self):
        result,interrupted,forced=self.run_child("import sys; sys.exit(7)")
        self.assertEqual(result.returncode,7)
        self.assertFalse(interrupted or forced)

    def test_timeout_preserves_output(self):
        with self.assertRaises(subprocess.TimeoutExpired) as failure:
            self.run_child("import time; print('before timeout',flush=True); time.sleep(30)",timeout=.2)
        self.assertIn("before timeout",failure.exception.output)

    def test_host_regressions_do_not_silently_allow_disconnect(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.run_child("import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text("
                "'METEOR_TRACKING_DISCONNECTED reason=test\\n'); time.sleep(30)",watch=False,timeout=.2)


if __name__=="__main__":
    unittest.main()
