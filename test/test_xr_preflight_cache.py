import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from xr_preflight_cache import ARTIFACTS, fingerprint, prepare, valid


class PreflightCacheTests(unittest.TestCase):
    def test_sources_build_commands_and_compiler_identity_invalidate(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            script=root / "tools/build_support/probe_monado_nvenc.sh"
            script.parent.mkdir(parents=True)
            script.write_text("commands v1")
            header=root / "test/example.h"
            header.parent.mkdir()
            header.write_text("header v1")
            compiler=root / "compiler"
            compiler.write_text("fixture")
            with patch("xr_preflight_cache.shutil.which",return_value=str(compiler)), patch("xr_preflight_cache.subprocess.check_output",return_value=b"compiler v1") as version:
                first=fingerprint(root,root)
                header.write_text("header v2")
                second=fingerprint(root,root)
                self.assertNotEqual(first,second)
                script.write_text("commands v2")
                third=fingerprint(root,root)
                self.assertNotEqual(second,third)
                version.return_value=b"compiler v2"
                self.assertNotEqual(third,fingerprint(root,root))

    def test_validated_hit_and_tamper_rebuild(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            def build(_root,_reference,directory):
                directory.mkdir(parents=True,exist_ok=True)
                for name in ARTIFACTS:
                    path=directory / name
                    path.write_bytes(b"validated fixture")
                    path.chmod(0o755)
            with patch("xr_preflight_cache.fingerprint",return_value="key"), patch("xr_preflight_cache.build",side_effect=build) as builder:
                self.assertFalse(prepare(root,root,root / "session1"))
                self.assertTrue(prepare(root,root,root / "session2"))
                cached=root / ".build-cache/meteor-xr/helper-cache/key"
                (cached / ARTIFACTS[0]).write_bytes(b"tampered")
                self.assertFalse(prepare(root,root,root / "session3"))
                self.assertEqual(builder.call_count,2)
                self.assertTrue(valid(cached,"key"))
                self.assertFalse(valid(cached,"different sources"))
                self.assertEqual((cached.parent.stat().st_mode & 0o777),0o700)

    def test_failed_build_is_not_validated(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            with patch("xr_preflight_cache.fingerprint",return_value="key"), patch("xr_preflight_cache.build",side_effect=subprocess.CalledProcessError(1,["test"])):
                with self.assertRaises(subprocess.CalledProcessError): prepare(root,root,root / "session")
            self.assertFalse(valid(root / ".build-cache/meteor-xr/helper-cache/key","key"))

    def test_sources_changing_during_build_are_not_validated(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            with patch("xr_preflight_cache.fingerprint",side_effect=["key","changed"]), patch("xr_preflight_cache.build"):
                with self.assertRaisesRegex(RuntimeError,"inputs changed"):
                    prepare(root,root,root / "session")
            self.assertFalse(valid(root / ".build-cache/meteor-xr/helper-cache/key","key"))

    def test_missing_or_modified_manifest_is_not_validated(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary)
            self.assertFalse(valid(directory,"key"))
            (directory / "validated.json").write_text("invalid")
            self.assertFalse(valid(directory,"key"))
            (directory / "validated.json").write_text("[]")
            self.assertFalse(valid(directory,"key"))
            (directory / "validated.json").write_text(json.dumps({"key":"key","artifacts":{}}))
            self.assertFalse(valid(directory,"key"))


if __name__=="__main__": unittest.main()
