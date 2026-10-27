import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
sys.path.insert(0, str(ROOT / 'test'))
from meteor_xr_runtime import prepare
from xr_preflight_cache import ARTIFACTS

spec = importlib.util.spec_from_file_location('stage_runtime', ROOT / 'tools/build_support/stage_meteor_xr_runtime.py')
staging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(staging)


class RuntimePackageTests(unittest.TestCase):
    def fixture(self, root):
        for name in staging.BINARIES:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b'fixture binary')
        for name in ('test/run_monado_nvenc_spike.py', 'test/xr_local_application.py',
                     'test/xr_launch_intent.py', 'tools/meteor_xr_runtime.py', 'tools/meteor_xr_install.py',
                     'tools/meteor_xr.py', 'tools/meteor_vr_library.py', 'LICENSE'):
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('')
        (root / 'test/run_monado_nvenc_spike.py').write_text('def launch():\n    from nested_runtime import run\n')
        (root / 'test/nested_runtime.py').write_text('def run(): pass\n')
        notices = root / '.build-cache/meteor-xr/monado-linux-spike/capture-source'
        for relative in ['LICENSE', 'LICENSES/BSL-1.0.txt', 'src/external/cjson/cjson/LICENSE']:
            path = notices / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture license')
        helpers = root / 'helpers'
        helpers.mkdir()
        hashes = {}
        for name in ARTIFACTS:
            path = helpers / name
            path.write_bytes(b'validated helper')
            path.chmod(0o755)
            hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        (helpers / 'validated.json').write_text(json.dumps({'key': 'fixture', 'artifacts': hashes}))
        return helpers

    def test_relocated_package_has_no_checkout_or_build_dependency(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'source'
            root.mkdir()
            helpers = self.fixture(root)
            destination = Path(tmp) / 'installed'
            staging.stage(root, destination, helpers)
            # Delete the source before checking the installed runtime.
            import shutil
            shutil.rmtree(root)
            prepare(destination, Path(tmp) / 'session')
            self.assertTrue((destination / 'test/nested_runtime.py').is_file())
            self.assertEqual((Path(tmp) / 'session/libmeteor-nvenc-probe.so').read_bytes(), b'validated helper')
            config = json.loads((destination / '.build-cache/meteor-xr/application.json').read_text())
            self.assertNotIn('openvr_compat', config)
            self.assertNotIn(str(root), json.dumps(config))

    def test_amd_encoder_and_private_ffmpeg_are_verified_and_relocated(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)/'source';root.mkdir();helpers=self.fixture(root)
            (root/'test/run_monado_nvenc_spike.py').write_text('from xr_encoder_backend import select\n')
            (root/'test/xr_encoder_backend.py').write_text('def select(): pass\n')
            bridge=root/'amd.so';bridge.write_bytes(b'AMD encoder')
            libraries=[]
            for name in ('libavcodec.so.62','libavutil.so.60'):
                source=root/name;source.write_bytes(b'private FFmpeg');libraries.append(source)
            installed=Path(temporary)/'installed'
            staging.stage(root,installed,helpers,system_libraries=libraries,vaapi=bridge)
            prepare(installed,Path(temporary)/'session')
            self.assertEqual((Path(temporary)/'session/libmeteor-vaapi-probe.so').read_bytes(),b'AMD encoder')
            self.assertTrue((installed/'xr-runtime/encoder-lib/libavcodec.so.62').is_file())
            self.assertFalse((installed/'xr-runtime/lib/libavcodec.so.62').exists())
            (installed/'xr-runtime/encoder-lib/libavcodec.so.62').write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError,'checksum mismatch'):
                prepare(installed,Path(temporary)/'another')
            self.assertFalse((Path(temporary)/'another').exists())

    def test_corrupt_runtime_rejected_before_session_creation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            helpers = self.fixture(root)
            destination = root / 'installed'
            staging.stage(root, destination, helpers)
            (destination / staging.BINARIES[0]).write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                prepare(destination, root / 'session')
            self.assertFalse((root / 'session').exists())

    def test_invalid_helpers_and_existing_destination_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            helpers = self.fixture(root)
            destination = root / 'installed'
            destination.mkdir()
            with self.assertRaises(FileExistsError):
                staging.stage(root, destination, helpers)
            (helpers / ARTIFACTS[0]).write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'validated build'):
                staging.stage(root, root / 'another', helpers)
            self.assertFalse((root / 'another').exists())

class RuntimeInstallTests(RuntimePackageTests):
    def test_bundled_xrizer_fresh_install_migration_and_custom_override(self):
        from meteor_xr_install import install
        from xr_local_application import application_environment
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'source'
            root.mkdir()
            helpers = self.fixture(root)
            xrizer = root / 'xrizer'
            for name in ('bin/linux64/vrclient.so', 'bin/version.txt', 'LICENSE',
                         'DEPENDENCY_NOTICES.txt', 'UPSTREAM_REVISION', 'SOURCE_URL', 'Cargo.lock'):
                path = xrizer / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fixture notice')
            header = bytearray(20)
            header[:6] = b'\x7fELF\x02\x01'
            header[18:20] = (62).to_bytes(2, 'little')
            (xrizer / 'bin/linux64/vrclient.so').write_bytes(header)
            package = Path(tmp) / 'package'
            staging.stage(root, package, helpers, xrizer=xrizer)
            destination = Path(tmp) / 'user-data'
            install(package, destination)
            config = destination / '.build-cache/meteor-xr/application.json'
            expected = str(destination / 'xr-runtime/xrizer')
            self.assertEqual(json.loads(config.read_text())['openvr_compat'], expected)
            selected = json.loads(config.read_text())
            selected['steam_app_id'] = '438100'
            config.write_text(json.dumps(selected))
            env = application_environment(config, {})
            self.assertEqual(env['VR_PATHREG_OVERRIDE'], str(config.parent / 'openvrpaths.vrpath'))
            self.assertEqual(env['VR_OVERRIDE'], str((destination / 'xr-runtime/xrizer').resolve()))
            session_spec = Path(tmp) / 'session-application.json'
            session_spec.write_text(config.read_text())
            self.assertEqual(application_environment(session_spec, {})['VR_PATHREG_OVERRIDE'],
                             str(config.parent / 'openvrpaths.vrpath'))
            spec = json.loads(config.read_text())
            spec['openvr_compat'] = '/var/lib/flatpak/app/io.github.wivrn.wivrn/x86_64/stable/active/files/xrizer'
            spec['steam_app_id'] = '438100'
            config.write_text(json.dumps(spec))
            install(package, destination)
            migrated = json.loads(config.read_text())
            self.assertEqual(migrated['openvr_compat'], expected)
            self.assertEqual(migrated['steam_app_id'], '438100')
            self.assertTrue(config.with_name('application.before-bundled-xrizer.json').is_file())
            spec['openvr_compat'] = '/my/custom/compat'
            original = json.dumps(spec)
            config.write_text(original)
            install(package, destination)
            self.assertEqual(config.read_text(), original)

    def test_export_excludes_local_state(self):
        from meteor_xr_install import export_package
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'source'
            root.mkdir()
            helpers = self.fixture(root)
            source = Path(tmp) / 'package'
            staging.stage(root, source, helpers)
            (source / '.build-cache/meteor-xr/private.key').write_text('do not ship')
            destination = Path(tmp) / 'export'
            export_package(source, destination)
            self.assertFalse((destination / '.build-cache/meteor-xr/private.key').exists())
            self.assertFalse((destination / '.build-cache/meteor-xr/application.json').exists())
            prepare(destination, Path(tmp) / 'session')

    def test_upgrade_preserves_local_settings_and_logs(self):
        from meteor_xr_install import install
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'source'
            root.mkdir()
            helpers = self.fixture(root)
            first = Path(tmp) / 'package1'
            staging.stage(root, first, helpers)
            destination = Path(tmp) / 'user-data'
            install(first, destination)
            cache = destination / '.build-cache/meteor-xr'
            config = cache / 'application.json'
            config.write_text('{"local": "keep"}')
            (cache / 'session.log').write_text('keep logs')
            old = (destination / 'tools').resolve()
            (root / 'tools/meteor_xr.py').write_text('# upgraded launcher\n')
            second = Path(tmp) / 'package2'
            staging.stage(root, second, helpers)
            install(second, destination)
            self.assertNotEqual(old, (destination / 'tools').resolve())
            self.assertTrue(old.exists())  # Previous version remains recoverable.
            self.assertEqual(config.read_text(), '{"local": "keep"}')
            self.assertEqual((cache / 'session.log').read_text(), 'keep logs')
            prepare(destination, Path(tmp) / 'session')

    def test_install_refuses_active_session_and_unmanaged_directory(self):
        import fcntl
        from meteor_xr_install import install
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / 'source'
            root.mkdir()
            helpers = self.fixture(root)
            source = Path(tmp) / 'package'
            staging.stage(root, source, helpers)
            destination = Path(tmp) / 'user-data'
            cache = destination / '.build-cache/meteor-xr'
            cache.mkdir(parents=True)
            with (cache / 'managed-session.lock').open('a') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                with self.assertRaisesRegex(RuntimeError, 'active XR session'):
                    install(source, destination)
            (destination / 'tools').mkdir()
            with self.assertRaisesRegex(ValueError, 'unmanaged'):
                install(source, destination)
            self.assertTrue((destination / 'tools').is_dir())


if __name__ == '__main__':
    unittest.main()
