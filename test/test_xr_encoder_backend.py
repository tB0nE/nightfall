import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import xr_encoder_backend as backend


class EncoderSelectionTests(unittest.TestCase):
    devices=[{'node':'/dev/dri/renderD128','vendor':'0x1002','pci':'0000:04:00.0'},
             {'node':'/dev/dri/renderD129','vendor':'0x10de','pci':'0000:05:00.0'}]

    def fixture(self, root):
        (root/'xr-runtime').mkdir()
        (root/'xr-runtime/manifest.json').write_text(json.dumps({'backends':['nvenc','vaapi']}))
        (root/'xr-runtime/libmeteor-vaapi-probe.so').write_bytes(b'fixture')
        out=root/'session';out.mkdir();return out

    def test_auto_preserves_nvidia_on_dual_gpu_machine(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);out=self.fixture(root)
            with patch.object(backend,'nvidia_available',return_value=True),patch.object(backend,'driver_manifest',return_value=Path('/nvidia.json')),patch.object(backend,'amd_codecs') as probe:
                result=backend.select(root,out,{'NIGHTFALL_XR_ENCODER_BACKEND':'auto'},self.devices)
            self.assertEqual(result[0],'nvenc');probe.assert_not_called()

    def test_auto_amd_requires_encoder_capability_and_pins_pci_gpu(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);out=self.fixture(root)
            env={'NIGHTFALL_XR_ENCODER_BACKEND':'auto','NIGHTFALL_XR_CODEC':'h265'}
            with patch.object(backend,'nvidia_available',return_value=False),patch.object(backend,'driver_manifest',return_value=Path('/amd.json')),patch.object(backend,'amd_codecs',return_value=['h264','h265']):
                result=backend.select(root,out,env,self.devices)
            self.assertEqual(result[0],'vaapi')
            self.assertEqual(result[3]['DRI_PRIME'],'pci-0000_04_00_0!')
            self.assertFalse(json.loads((out/'encoder-selection.json').read_text())['live_bitrate'])

    def test_unavailable_amd_encoder_does_not_silently_use_cpu_or_other_gpu(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);out=self.fixture(root)
            with patch.object(backend,'amd_codecs',return_value=[]):
                with self.assertRaisesRegex(RuntimeError,'hardware H.264/HEVC'):
                    backend.select(root,out,{'NIGHTFALL_XR_ENCODER_BACKEND':'vaapi'},self.devices)
            self.assertFalse((out/'encoder-selection.json').exists())

    def test_multiple_amd_devices_require_explicit_selection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);out=self.fixture(root)
            devices=self.devices+[dict(self.devices[0],node='/dev/dri/renderD130')]
            with self.assertRaisesRegex(RuntimeError,'Select one AMD GPU'):
                backend.select(root,out,{'NIGHTFALL_XR_ENCODER_BACKEND':'vaapi'},devices)
            with self.assertRaisesRegex(RuntimeError,'Select one AMD GPU'):
                backend.select(root,out,{'NIGHTFALL_XR_ENCODER_BACKEND':'vaapi','NIGHTFALL_XR_RENDER_DEVICE':'/dev/dri/renderD129'},devices)

    def test_unsupported_profile_and_legacy_package_report_clear_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);out=self.fixture(root)
            with patch.object(backend,'amd_codecs',return_value=['h264','h265']):
                for values,message in [({'NIGHTFALL_XR_CODEC':'av1'},'requested XR codec'),({'NIGHTFALL_XR_CODEC':'h265','NIGHTFALL_XR_FOVEATED_ENCODING':'1'},'Foveated')]:
                    with self.assertRaisesRegex(RuntimeError,message):
                        backend.select(root,out,dict(values,NIGHTFALL_XR_ENCODER_BACKEND='vaapi'),self.devices)
            (root/'xr-runtime/manifest.json').write_text('{}')
            with self.assertRaisesRegex(RuntimeError,'updated Meteor'):
                backend.select(root,out,{'NIGHTFALL_XR_ENCODER_BACKEND':'vaapi'},self.devices)

    def test_amd_h264_uses_the_real_advertised_codec_list(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);out=self.fixture(root)
            env={'NIGHTFALL_XR_ENCODER_BACKEND':'vaapi','NIGHTFALL_XR_CODEC':'h264'}
            with patch.object(backend,'driver_manifest',return_value=Path('/amd.json')),patch.object(backend,'amd_codecs',return_value=['h264','h265']):
                self.assertEqual(backend.select(root,out,env,self.devices)[0],'vaapi')
            with patch.object(backend,'amd_codecs',return_value=['h265']):
                with self.assertRaisesRegex(RuntimeError,'requested XR codec'):
                    backend.select(root,out,env,self.devices)

    def test_ubuntu_and_fedora_driver_manifest_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);p=root/'nvidia_icd.json';p.write_text('{}')
            self.assertEqual(backend.driver_manifest('nvenc',[root]),p)
            p=root/'radeon_icd.x86_64.json';p.write_text('{}')
            self.assertEqual(backend.driver_manifest('vaapi',[root]),p)


if __name__=='__main__':unittest.main()
