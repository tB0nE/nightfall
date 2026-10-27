import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
import unittest
from xr_launch_intent import publish_intent, desktop_mode, alive
from xr_local_application import wait_for_local_launch

ROOT=Path(__file__).resolve().parents[1]

class LaunchIntentTests(unittest.TestCase):
    def scaffold(self,root):
        cache=root/".build-cache/meteor-xr"
        cache.mkdir(parents=True)
        (cache/"application.json").write_text(json.dumps({"launch":"steam","steam_app_id":"438100"}))
        (root/"tools").mkdir()
        (root/"test").mkdir()
        shutil.copy2(ROOT/"tools/meteor_xr.py",root/"tools/meteor_xr.py")
        for name in ("xr_local_application.py","xr_launch_intent.py"):
            shutil.copy2(ROOT/"test"/name,root/"test"/name)
        return cache

    def test_private_bounded_single_owner_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); cache=self.scaffold(root)
            with publish_intent(root,"438100",120) as generation:
                path=cache/"auto-launch/intent.json"
                value=json.loads(path.read_text())
                self.assertEqual(value["generation"],generation)
                self.assertTrue(alive(value))
                self.assertEqual(path.stat().st_mode&0o777,0o600)
                self.assertNotIn("argv",value)
                with self.assertRaises(RuntimeError):
                    with publish_intent(root,"438100",120): pass
                self.assertFalse(alive(dict(value,start_ticks=value["start_ticks"]+1)))
            self.assertFalse(path.exists())
            with self.assertRaises(ValueError):
                with publish_intent(root,"123",120): pass

    def test_automatic_wrapper_waits_for_intent_bound_runtime(self):
        self.check_automatic_wrapper("438100", "438100")

    def test_wildcard_wrapper_launches_different_game(self):
        self.check_automatic_wrapper("*", "546560")

    def check_automatic_wrapper(self, configured_app, app_id):
        with tempfile.TemporaryDirectory() as temporary, ThreadPoolExecutor() as pool:
            root=Path(temporary); cache=self.scaffold(root)
            (cache/"application.json").write_text(json.dumps({"launch":"steam","steam_app_id":configured_app}))
            wrapper=subprocess.Popen([sys.executable,str(root/"tools/meteor_xr.py"),"steam-run","--app-id",app_id,"--wait","10","--",sys.executable,"-c","raise SystemExit(7)"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                path=cache/"auto-launch/intent.json"
                deadline=time.monotonic()+3
                while not path.exists():
                    if wrapper.poll() is not None or time.monotonic()>deadline: self.fail("No automatic intent")
                    time.sleep(.01)
                intent=json.loads(path.read_text())
                output=cache/"lan-sessions/automatic"
                output.mkdir(parents=True)
                future=pool.submit(wait_for_local_launch,output,{"METEOR_XR_RUNTIME_GENERATION":"e"*32,"METEOR_XR_LAUNCH_INTENT":intent["generation"]},timeout=4,steam_app_id=app_id)
                value=future.result(timeout=5)
                self.assertEqual(value["owner_pid"],wrapper.pid)
                self.assertEqual(value["app_id"],app_id)
                game=subprocess.run(value["argv"])
                (output/"steam-outcome.json").write_text(json.dumps({"generation":"e"*32,"app_id":app_id,"returncode":game.returncode,"interrupted":False}))
                _,stderr=wrapper.communicate(timeout=4)
                self.assertEqual(wrapper.returncode,7,stderr)
                self.assertFalse(path.exists())
            finally:
                if wrapper.poll() is None: wrapper.kill()
                wrapper.communicate()

    def test_desktop_launch_does_not_need_runtime_or_intent(self):
        self.assertTrue(desktop_mode(["game","--no-vr"]))
        self.assertFalse(desktop_mode(["game","--vr"]))
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); cache=self.scaffold(root)
            result=subprocess.run([sys.executable,str(root/"tools/meteor_xr.py"),"steam-run","--app-id","438100","--",sys.executable,"-c","print('desktop-mode')","--no-vr"],capture_output=True,text=True,timeout=3)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn("desktop-mode",result.stdout)
            self.assertFalse((cache/"auto-launch/intent.json").exists())
