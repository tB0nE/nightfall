import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import time
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from xr_local_application import load_application, validate_capture, wait_for_local_launch, request_local_launch, find_armed_session, application_environment, validate_openvr_compat
from xr_application_lifecycle import run_application


class LocalApplicationTests(unittest.TestCase):
    def test_session_discovery_filters_expired_and_rejects_ambiguity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, expiry in (("old",time.time()-1),("live",time.time()+20)):
                session = root/name
                session.mkdir()
                (session/"application-ready.json").write_text(json.dumps({"state":"ready","generation":"a"*32,"pid":os.getpid(),"expires_at":expiry}))
            self.assertEqual(find_armed_session(root),root/"live")
            second=root/"second"
            second.mkdir()
            (second/"application-ready.json").write_text((root/"live/application-ready.json").read_text())
            with self.assertRaisesRegex(RuntimeError,"Multiple"): find_armed_session(root)
            (second/"application-launch.json").write_text("{}")
            self.assertEqual(find_armed_session(root),root/"live")

    def test_compatibility_settings_are_child_scoped_and_validated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root/"compat/bin/linux64/vrclient.so"
            library.parent.mkdir(parents=True)
            header = bytearray(20)
            header[:6]=b"\x7fELF\x02\x01"
            header[18:20]=(62).to_bytes(2,"little")
            library.write_bytes(header)
            spec = root/"application.json"
            spec.write_text(json.dumps({"argv":[sys.executable],"cwd":directory,"openvr_compat":str(root/"compat"),"steam_runtime":True}))
            inherited={"XR_RUNTIME_JSON":"/private/runtime.json","XDG_RUNTIME_DIR":"/private/ipc","KEEP":"original"}
            env = application_environment(spec,inherited)
            self.assertEqual(env["VR_OVERRIDE"],str(root/"compat"))
            self.assertEqual(env["PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES"],"1")
            self.assertEqual(env["PRESSURE_VESSEL_FILESYSTEMS_RO"],str(root/"compat"))
            self.assertEqual(env["XR_RUNTIME_JSON"],inherited["XR_RUNTIME_JSON"])
            self.assertNotIn("VR_OVERRIDE",inherited)
            with patch("xr_local_application.validate_openvr_compat",return_value=Path("/usr/share/xrizer")):
                mapped = application_environment(spec,inherited)
            self.assertEqual(mapped["VR_OVERRIDE"],"/run/host/usr/share/xrizer")
            spec.write_text(json.dumps({"argv":[sys.executable],"cwd":directory,"steam_runtime":True}))
            native = application_environment(spec,inherited)
            self.assertEqual(native["PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES"],"1")
            self.assertNotIn("VR_OVERRIDE",native)
            library.write_bytes(b"not an ELF library")
            with self.assertRaises(ValueError): validate_openvr_compat(str(root/"compat"))

    def test_armed_runtime_waits_for_local_generation_bound_request(self):
        with tempfile.TemporaryDirectory() as directory, ThreadPoolExecutor() as pool:
            root = Path(directory)
            future = pool.submit(wait_for_local_launch, root, {"METEOR_XR_RUNTIME_GENERATION": "a"*32}, timeout=2)
            deadline = time.monotonic()+1
            while not (root / "application-ready.json").exists():
                if time.monotonic()>deadline: self.fail("Not armed")
                time.sleep(.01)
            self.assertFalse(future.done())
            request_local_launch(root)
            future.result(timeout=2)
            self.assertFalse((root / "application-ready.json").exists())
            with self.assertRaises(FileNotFoundError): request_local_launch(root)

    def test_arming_timeout_cancel_and_stale_files_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(TimeoutError): wait_for_local_launch(root, {}, timeout=.01)
            self.assertFalse((root / "application-ready.json").exists())
            with self.assertRaisesRegex(RuntimeError,"cancelled"):
                wait_for_local_launch(root, {}, cancelled=lambda: True)
            (root / "application-launch.json").write_text("{}")
            with self.assertRaisesRegex(RuntimeError,"stale"):
                wait_for_local_launch(root,{})

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

    def test_live_output_survives_interruption_and_retains_game_panic(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "service.log"
            log.write_text("")
            output = root / "application-live.log"
            def owner_alive():
                # Must already be readable before run_application returns.
                return "xrizer diagnostic" not in output.read_text()
            result, interrupted, forced = run_application(
                [sys.executable, "-c", "import sys,time; print('xrizer diagnostic',file=sys.stderr,flush=True); time.sleep(30)"],
                env=dict(os.environ), timeout=2, service_log=log, stop_file=root / "stop",
                terminate_on_stop=True, owner_alive=owner_alive, output_path=output)
            self.assertTrue(interrupted)
            self.assertFalse(forced)
            self.assertEqual(result.stdout, output.read_text())
            self.assertIn("xrizer diagnostic", result.stdout)

    def test_live_output_survives_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "service.log"
            log.write_text("")
            output = root / "application-live.log"
            import subprocess
            with self.assertRaises(subprocess.TimeoutExpired) as failure:
                run_application([sys.executable, "-c", "import time; print('before timeout',flush=True); time.sleep(30)"],
                    env=dict(os.environ), timeout=.3, service_log=log,
                    stop_file=root / "stop", terminate_on_stop=True, output_path=output)
            self.assertIn("before timeout", output.read_text())
            self.assertEqual(failure.exception.output, output.read_text())

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
