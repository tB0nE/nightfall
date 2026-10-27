import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release_metadata', ROOT/'meteor/tools/release_metadata.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseSourceTests(unittest.TestCase):
    def test_source_selection_excludes_credentials_caches_and_signing_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            subprocess.run(['git','init','-q',str(root)],check=True)
            (root/'.gitignore').write_text('meteor/target/\n')
            for name in ['meteor/src/main.rs','meteor/RELEASE.md','meteor/.env',
                         'meteor/signing/release.keystore','meteor/signing/key.pem',
                         'meteor/target/private.log','.build-cache/session.log','LICENSE']:
                path=root/name
                path.parent.mkdir(parents=True,exist_ok=True)
                path.write_text('fixture')
            self.assertEqual(release.sources(root), ['LICENSE','meteor/RELEASE.md','meteor/src/main.rs'])


if __name__ == '__main__': unittest.main()
