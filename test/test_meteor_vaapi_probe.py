import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run_meteor_vaapi_probe as probe


class VaapiProbeTests(unittest.TestCase):
    def test_failed_boot_cannot_accidentally_repeat_a_gpu_probe(self):
        with tempfile.TemporaryDirectory() as directory:
            marker=Path(directory)/'failed-boot.json'
            marker.write_text(json.dumps({'boot_id':'failed'}))
            with patch.object(probe,'boot_id',return_value='failed'):
                with self.assertRaisesRegex(RuntimeError,'Reboot'):probe.require_healthy_boot(marker)
            with patch.object(probe,'boot_id',return_value='new-boot'):
                probe.require_healthy_boot(marker)

    def test_amd_selection_does_not_depend_on_render_node_numbering(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            for name,vendor in [('renderD128','0x10de'),('renderD129','0x1002')]:
                path=root/name/'device'
                path.mkdir(parents=True)
                (path/'vendor').write_text(vendor)
            self.assertEqual(probe.amd_device(root),'/dev/dri/renderD129')
            path=root/'renderD130/device';path.mkdir(parents=True);(path/'vendor').write_text('0x1002')
            with self.assertRaisesRegex(RuntimeError,'Specify --device'):probe.amd_device(root)


if __name__=='__main__':unittest.main()
