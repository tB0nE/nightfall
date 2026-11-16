import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from xr_runtime_registration import RegistrationGroup
from xr_runtime_paths import socket_name, socket_path, ACTIVATION_SOCKET, LEGACY_SOCKET


class RegistrationGroupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nf-register-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root/'config'
        self.state = self.root/'state'
        self.manifest = self.root/'runtime.json'
        self.manifest.write_text(json.dumps(dict(runtime=dict(library_path='/fixture.so'))))
        self.xrizer = self.root/'xrizer'
        library = self.xrizer/'bin/linux64/vrclient.so'
        library.parent.mkdir(parents=True)
        header = bytearray(20); header[:6] = b'\x7fELF\x02\x01'; header[18:20] = (62).to_bytes(2,'little')
        library.write_bytes(header)
        self.generic = self.config/'openxr/1/active_runtime.json'
        self.arch = self.config/'openxr/1/active_runtime.x86_64.json'
        self.registry = self.config/'openvr/openvrpaths.vrpath'

    def original(self):
        self.generic.parent.mkdir(parents=True)
        self.generic.write_text('old runtime')
        self.arch.symlink_to('../other-runtime.json')
        self.registry.parent.mkdir(parents=True)
        self.registry.write_text(json.dumps(dict(runtime=['/steamvr'],external_drivers=['/other-driver'],config=['/config'])))
        return self.registry.read_bytes()

    def test_group_preserves_all_selectors_and_unrelated_driver_keys(self):
        previous = self.original()
        with RegistrationGroup(self.config,self.state) as group:
            group.register(self.manifest,self.xrizer)
            self.assertEqual(self.generic.resolve(),self.manifest)
            self.assertEqual(self.arch.resolve(),self.manifest)
            value = json.loads(self.registry.read_text())
            self.assertEqual(value['runtime'],[str(self.xrizer)])
            self.assertEqual(value['external_drivers'],['/other-driver'])
        self.assertEqual(self.generic.read_text(),'old runtime')
        self.assertEqual(str(self.arch.readlink()),'../other-runtime.json')
        self.assertEqual(self.registry.read_bytes(),previous)

    def test_partial_failure_rolls_back_other_entries(self):
        previous = self.original()
        from xr_runtime_registration import acquire
        def fail(destination,target,journal):
            if destination == self.registry:
                raise OSError('simulated registry failure')
            return acquire(destination,target,journal)
        with RegistrationGroup(self.config,self.state) as group:
            with patch('xr_runtime_registration.acquire',fail):
                with self.assertRaises(OSError):
                    group.register(self.manifest,self.xrizer)
        self.assertEqual(self.generic.read_text(),'old runtime')
        self.assertTrue(self.arch.is_symlink())
        self.assertEqual(self.registry.read_bytes(),previous)

    def test_in_place_foreign_edit_is_retained_and_blocks_reacquisition(self):
        self.original()
        with RegistrationGroup(self.config,self.state) as group:
            group.register(self.manifest,self.xrizer)
            self.registry.write_text('{"runtime":["/changed-by-user"]}')
        self.assertEqual(json.loads(self.registry.read_text())['runtime'],['/changed-by-user'])
        self.assertEqual(self.generic.read_text(),'old runtime')
        with self.assertRaisesRegex(RuntimeError,'changed externally'):
            with RegistrationGroup(self.config,self.state):
                self.fail('Foreign configuration was overwritten')

    def test_process_crash_is_recovered_before_next_registration(self):
        previous = self.original()
        script = '''import os,sys
from pathlib import Path
from xr_runtime_registration import RegistrationGroup
group=RegistrationGroup(Path(sys.argv[1]),Path(sys.argv[2])); group.__enter__()
group.register(Path(sys.argv[3]),Path(sys.argv[4]))
os._exit(0)
'''
        subprocess.run([sys.executable,'-c',script,str(self.config),str(self.state),str(self.manifest),str(self.xrizer)],
                       env=dict(os.environ,PYTHONPATH=str(Path(__file__).parent)),check=True,timeout=3)
        self.assertEqual(self.generic.resolve(),self.manifest)
        with RegistrationGroup(self.config,self.state):
            self.assertEqual(self.generic.read_text(),'old runtime')
            self.assertEqual(self.registry.read_bytes(),previous)

    def test_competing_owner_and_invalid_registry_do_not_change_selectors(self):
        self.original()
        with RegistrationGroup(self.config,self.state):
            with self.assertRaises(BlockingIOError):
                with RegistrationGroup(self.config,self.state):
                    self.fail('Concurrent registration succeeded')
        self.registry.write_text('invalid json')
        with RegistrationGroup(self.config,self.state) as group:
            with self.assertRaises(ValueError):
                group.register(self.manifest,self.xrizer)
        self.assertEqual(self.generic.read_text(),'old runtime')

    def test_registration_helper_restores_on_owner_pipe_eof(self):
        previous = self.original()
        cache = self.root/'.build-cache/meteor-xr'
        cache.mkdir(parents=True)
        tools = Path(__file__).resolve().parents[1]/'tools'
        # Use fixture library paths to exercise the real helper lifecycle
        # without constructing or selecting an actual runtime on this PC.
        script = """import sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import meteor_xr_register as registration
root=Path(sys.argv[2]); xrizer=Path(sys.argv[3])
registration.registration_inputs=lambda ignored: (root/'fixture.so',xrizer)
sys.argv=['meteor_xr_register','--root',str(root)]
registration.main()
"""
        child = subprocess.Popen([sys.executable,'-c',script,str(tools),str(self.root),str(self.xrizer)],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,
            env=dict(os.environ,XDG_CONFIG_HOME=str(self.config)))
        try:
            import select
            self.assertTrue(select.select([child.stdout],[],[],3)[0])
            self.assertTrue(json.loads(child.stdout.readline())['ready'])
            self.assertEqual(json.loads(self.registry.read_text())['runtime'],[str(self.xrizer)])
            child.stdin.close(); child.stdin=None
            _, error = child.communicate(timeout=3)
            self.assertEqual(child.returncode,0,error)
        finally:
            if child.poll() is None:
                child.kill()
            child.communicate()
        self.assertEqual(self.generic.read_text(),'old runtime')
        self.assertEqual(self.registry.read_bytes(),previous)

    def test_socket_abi_is_explicit_and_legacy_bundles_remain_supported(self):
        self.assertEqual(socket_name(self.root),LEGACY_SOCKET)
        stamp = self.root/'.build-cache/meteor-xr/monado-linux-spike/ipc-socket-name'
        stamp.parent.mkdir(parents=True)
        stamp.write_text(ACTIVATION_SOCKET+'\n')
        self.assertEqual(socket_name(self.root),ACTIVATION_SOCKET)
        endpoint = socket_path(self.root,self.root/'run',prepare=True)
        self.assertEqual(endpoint,self.root/'run'/ACTIVATION_SOCKET)
        self.assertTrue(endpoint.parent.is_dir())
        stamp.write_text('../foreign.sock')
        with self.assertRaises(ValueError):
            socket_name(self.root)


if __name__ == '__main__':
    unittest.main()
