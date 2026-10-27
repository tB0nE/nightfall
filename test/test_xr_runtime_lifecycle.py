import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

from xr_runtime_lifecycle import managed_runtime


class RuntimeLifecycleTests(unittest.TestCase):
    def test_ready_without_launching_application_and_reaped_on_scope_exit(self):
        with tempfile.TemporaryDirectory(prefix="nf-runtime-") as directory:
            root = Path(directory)
            ready, state = root / "ipc", root / "state.json"
            command = [sys.executable, "-c",
                       "import socket,sys,time; s=socket.socket(socket.AF_UNIX); "
                       "s.bind(sys.argv[1]); s.listen(); time.sleep(30)", str(ready)]
            with managed_runtime(command, env=dict(os.environ), ready_path=ready,
                                 log_path=root / "log", state_path=state) as child:
                record = json.loads(state.read_text())
                self.assertEqual(record["state"], "runtime_ready")
                self.assertFalse(record["application_session_observed"])
                self.assertIsNone(child.poll())
            self.assertIsNotNone(child.poll())
            self.assertEqual(json.loads(state.read_text())["state"], "stopped")

    def test_startup_timeout_reaps_child(self):
        with tempfile.TemporaryDirectory(prefix="nf-runtime-") as directory:
            root = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "timed out"):
                with managed_runtime([sys.executable, "-c", "import time; time.sleep(30)"],
                                     env=dict(os.environ), ready_path=root / "ipc",
                                     log_path=root / "log", state_path=root / "state.json",
                                     startup_timeout=.05):
                    self.fail("Never ready")
            record = json.loads((root / "state.json").read_text())
            self.assertEqual(record["state"], "stopped")
            with self.assertRaises(ProcessLookupError):
                os.kill(record["pid"], 0)

    def test_early_exit_is_not_readiness(self):
        with tempfile.TemporaryDirectory(prefix="nf-runtime-") as directory:
            root = Path(directory)
            with self.assertRaisesRegex(RuntimeError, "before readiness"):
                with managed_runtime([sys.executable, "-c", "raise SystemExit(7)"],
                                     env=dict(os.environ), ready_path=root / "ipc",
                                     log_path=root / "log", state_path=root / "state.json"):
                    self.fail("Exited service")

    def test_existing_endpoint_is_rejected_without_launch(self):
        with tempfile.TemporaryDirectory(prefix="nf-runtime-") as directory:
            root = Path(directory)
            (root / "ipc").write_text("stale")
            with self.assertRaisesRegex(RuntimeError, "pre-existing"):
                with managed_runtime(["/must-not-execute"], env=dict(os.environ),
                                     ready_path=root / "ipc", log_path=root / "log",
                                     state_path=root / "state.json"):
                    self.fail("Stale endpoint")

    def test_cancelled_startup_is_reaped(self):
        with tempfile.TemporaryDirectory(prefix="nf-runtime-") as directory:
            root = Path(directory)
            (root / "cancel").touch()
            with self.assertRaisesRegex(RuntimeError, "cancelled"):
                with managed_runtime([sys.executable, "-c", "import time; time.sleep(30)"],
                                     env=dict(os.environ), ready_path=root / "ipc",
                                     log_path=root / "log", state_path=root / "state.json",
                                     cancel_path=root / "cancel"):
                    self.fail("Cancelled startup")
            self.assertEqual(json.loads((root / "state.json").read_text())["state"], "stopped")

    def test_application_failure_still_reaps_unresponsive_runtime(self):
        with tempfile.TemporaryDirectory(prefix="nf-runtime-") as directory:
            root = Path(directory)
            command = [sys.executable, "-c",
                       "import signal,socket,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                       "s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); "
                       "s.listen(); time.sleep(30)", str(root / "ipc")]
            with self.assertRaisesRegex(ValueError, "application failed"):
                with managed_runtime(command, env=dict(os.environ), ready_path=root / "ipc",
                                     log_path=root / "log", state_path=root / "state.json",
                                     stop_timeout=.05) as child:
                    raise ValueError("application failed")
            self.assertIsNotNone(child.poll())
            self.assertEqual(json.loads((root / "state.json").read_text())["state"], "stopped")


if __name__ == "__main__":
    unittest.main()
