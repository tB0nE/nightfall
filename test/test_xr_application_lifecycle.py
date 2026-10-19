import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from xr_application_lifecycle import run_application


class ApplicationLifecycleTests(unittest.TestCase):
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
