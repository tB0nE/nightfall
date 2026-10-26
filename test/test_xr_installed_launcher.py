import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from meteor_xr import installed_launcher

class InstalledLauncherTests(unittest.TestCase):
    def test_disabled_config_keeps_explicit_checkout_behavior(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            config=root/'meteor.toml';config.write_text('[xr]\nenabled=false\n')
            self.assertIsNone(installed_launcher(root,config,root/'installed'))

    def test_enabled_config_validates_and_selects_installed_wrapper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); installed=root/'installed'
            (installed/'tools').mkdir(parents=True)
            (installed/'tools/meteor_xr.py').write_text('fixture')
            (installed/'xr-runtime').mkdir()
            (installed/'xr-runtime/manifest.json').write_text('{}')
            config=root/'meteor.toml';config.write_text('[xr]\nenabled=true\n')
            with patch('meteor_xr_runtime.validate') as check:
                self.assertEqual(installed_launcher(root,config,installed),installed/'tools/meteor_xr.py')
                check.assert_called_once_with(installed)
            self.assertIsNone(installed_launcher(installed,config,installed))

    def test_missing_installed_runtime_fails_instead_of_publishing_to_wrong_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            config=root/'meteor.toml';config.write_text('[xr]\nenabled=true\n')
            with self.assertRaisesRegex(ValueError,'runtime is missing'):
                installed_launcher(root,config,root/'absent')

if __name__=='__main__': unittest.main()
