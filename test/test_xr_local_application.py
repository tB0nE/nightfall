import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

from xr_local_application import load_application, validate_capture
from xr_application_lifecycle import run_application


class LocalApplicationTests(unittest.TestCase):
    def test_selection_is_exact_argv_not_a_shell_command(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.json"
            args = [sys.executable, "literal; $(not-a-shell)", ""]
            path.write_text(json.dumps({"argv": args, "cwd": directory}))
            self.assertEqual(load_application(path), (args, directory))
            for value in (
                {"argv": "echo nope", "cwd": directory},
                {"argv": [], "cwd": directory},
                {"argv": ["python"], "cwd": directory},
                {"argv": [sys.executable, 1], "cwd": directory},
                {"argv": [sys.executable, "bad\0arg"], "cwd": directory},
                {"argv": [sys.executable], "cwd": "."},
                {"argv": [sys.executable], "cwd": directory, "env": {}},
            ):
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError): load_application(path)
            path.write_text(" " * 16385)
            with self.assertRaises(ValueError): load_application(path)

    def test_external_app_uses_runtime_environment_and_local_working_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "service.log"
            log.write_text("")
            env = dict(os.environ, XR_RUNTIME_JSON="/private/session/runtime.json")
            result, interrupted, forced = run_application(
                [sys.executable, "-c", "import os; print(os.getcwd()); print(os.environ['XR_RUNTIME_JSON'])"],
                env=env, cwd=directory, timeout=2, service_log=log,
                stop_file=root / "stop", terminate_on_stop=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.splitlines(), [directory, env["XR_RUNTIME_JSON"]])
            self.assertFalse(interrupted or forced)

    def test_unmodified_app_does_not_need_fixture_exit_hook(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "service.log"
            log.write_text("")
            result, interrupted, forced = run_application(
                [sys.executable, "-c",
                 "import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('cancel'); time.sleep(30)",
                 str(root / "stop")], env=dict(os.environ), cwd=directory, timeout=2,
                service_log=log, stop_file=root / "stop", terminate_on_stop=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(interrupted)
            self.assertFalse(forced)

    def test_background_stdin_does_not_signal_eof_or_steal_host_input(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "service.log"
            log.write_text("")
            result, interrupted, forced = run_application(
                [sys.executable, "-c",
                 "import select,sys; print(bool(select.select([sys.stdin],[],[],.15)[0]))"],
                env=dict(os.environ), timeout=2, service_log=log,
                stop_file=root / "stop", terminate_on_stop=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), "False")
            self.assertFalse(interrupted or forced)

    def test_capture_cannot_claim_fixture_success_or_missing_drain(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = {"offset": 0, "bytes": 3, "frame_id": 1, "display_time_ns": 123}
            (root / "monado-stereo.jsonl").write_text(json.dumps(record) + "\n")
            (root / "monado-stereo.h264").write_bytes(b"abc")
            log = "METEOR_IMAGE_LEASE retain=1 x\nMETEOR_IMAGE_LEASE retain=0 x\nMETEOR_ENCODER_DRAIN frames=1 x\nMETEOR_ENCODER_RELEASED\n"
            self.assertEqual(validate_capture(root, log), 1)
            with self.assertRaises(RuntimeError): validate_capture(root, "")
            (root / "monado-stereo.h264").write_bytes(b"abcd")
            with self.assertRaises(RuntimeError): validate_capture(root, log)


if __name__ == "__main__":
    unittest.main()
