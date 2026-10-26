import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
import unittest

from xr_local_application import request_steam_launch, validate_steam_request, wait_for_local_launch, request_local_launch
from xr_application_lifecycle import run_application

ROOT=Path(__file__).resolve().parents[1]


class SteamLauncherTests(unittest.TestCase):
    def test_shortcut_zero_app_id_requires_matching_64_bit_game_id(self):
        app_id="2944203442"
        value={"generation":"a"*32,"action":"steam_launch","app_id":app_id,
               "argv":[sys.executable],"cwd":str(ROOT),"owner_pid":os.getpid(),
               "environment":{"SteamAppId":"0","STEAM_COMPAT_APP_ID":"0",
                              "SteamGameId":str((int(app_id)<<32)|0x02000000)}}
        validate_steam_request(value,"a"*32,app_id)
        value['environment']['SteamGameId']=str((123<<32)|0x02000000)
        with self.assertRaisesRegex(ValueError,'ID mismatch'):
            validate_steam_request(value,"a"*32,app_id)

    def test_local_command_is_app_bound_and_secrets_are_not_forwarded(self):
        with tempfile.TemporaryDirectory() as directory, ThreadPoolExecutor() as pool:
            root=Path(directory)
            future=pool.submit(wait_for_local_launch,root,{"METEOR_XR_RUNTIME_GENERATION":"b"*32},timeout=3,steam_app_id="438100")
            deadline=time.monotonic()+2
            while not (root/"application-ready.json").exists():
                if time.monotonic()>deadline: self.fail("Not armed")
                time.sleep(.01)
            with self.assertRaises(RuntimeError): request_local_launch(root)
            with self.assertRaises(ValueError): request_steam_launch(root,"123",[sys.executable],directory,{})
            request_steam_launch(root,"438100",[sys.executable,"literal; $(not-shell)"],directory,
                                 {"SteamAppId":"438100","STEAM_COMPAT_DATA_PATH":"/steam/prefix","SSH_AUTH_SOCK":"secret","XR_RUNTIME_JSON":"bad"})
            value=future.result(timeout=3)
            self.assertEqual(value["argv"][1],"literal; $(not-shell)")
            self.assertNotIn("SSH_AUTH_SOCK",value["environment"])
            self.assertNotIn("XR_RUNTIME_JSON",value["environment"])
            invalid=dict(value,environment={"XR_RUNTIME_JSON":"bad"})
            with self.assertRaises(ValueError): validate_steam_request(invalid,"b"*32,"438100")
            with self.assertRaises(ValueError): validate_steam_request(value,"c"*32,"438100")

    def test_wrapper_waits_and_returns_owned_game_exit_code(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            ticket={"generation":"d"*32,"pid":os.getpid(),"state":"ready","expires_at":time.time()+5,"steam_app_id":"438100"}
            (root/"application-ready.json").write_text(json.dumps(ticket))
            wrapper=subprocess.Popen([sys.executable,str(ROOT/"tools/meteor_xr.py"),"steam-run","--app-id","438100","--session",directory,"--",sys.executable,"-c","raise SystemExit(7)"],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                deadline=time.monotonic()+3
                while not (root/"application-launch.json").exists():
                    if wrapper.poll() is not None or time.monotonic()>deadline: self.fail("No launch request")
                    time.sleep(.01)
                value=json.loads((root/"application-launch.json").read_text())
                validate_steam_request(value,ticket["generation"],"438100")
                self.assertIsNone(wrapper.poll())
                game=subprocess.run(value["argv"],cwd=value["cwd"])
                (root/"steam-outcome.json").write_text(json.dumps({"generation":ticket["generation"],"app_id":"438100","returncode":game.returncode,"interrupted":False}))
                stdout,stderr=wrapper.communicate(timeout=3)
                self.assertEqual(wrapper.returncode,7,stderr)
            finally:
                if wrapper.poll() is None: wrapper.kill()
                wrapper.communicate()

    def test_game_stops_when_local_steam_wrapper_disappears(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            log=root/"service.log"
            log.write_text("")
            result,interrupted,forced=run_application([sys.executable,"-c","import time; time.sleep(30)"],
                env=dict(os.environ),timeout=3,service_log=log,stop_file=root/"stop",terminate_on_stop=True,owner_alive=lambda:False)
            self.assertTrue(interrupted)
            self.assertFalse(forced)
            self.assertNotEqual(result.returncode,0)


if __name__=="__main__": unittest.main()
