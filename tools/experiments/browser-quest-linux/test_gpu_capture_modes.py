#!/usr/bin/python3
"""Check that the diagnostic actually omits source operations; no GPU calls."""
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import Mock,patch
spec=importlib.util.spec_from_file_location('capture',Path(__file__).with_name('gpu-x11-capture.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class CaptureModes(unittest.TestCase):
    def test_invalid_mode_rejected_before_connecting(self):
        with patch.object(module.socket,'socket') as connect:
            with self.assertRaises(ValueError):module.GpuCapture({},mode='invalid')
            connect.assert_not_called()

    def test_untiled_policy_is_explicit_and_invalid_policy_does_not_mutate_environment(self):
        with patch.dict(os.environ,{},clear=True):
            self.assertEqual(module.apply_driver_policy('default'),'default')
            self.assertNotIn('FD_MESA_DEBUG',os.environ)
            with self.assertRaises(ValueError):module.apply_driver_policy('bogus')
            self.assertNotIn('FD_MESA_DEBUG',os.environ)
            self.assertEqual(module.apply_driver_policy('sysmem'),'sysmem')
            self.assertEqual(os.environ['FD_MESA_DEBUG'],'sysmem')
            self.assertEqual(module.apply_driver_policy('linear'),'linear')
            self.assertEqual(os.environ['FD_MESA_DEBUG'],'notile,noubwc')

    def exercise(self,mode):
        capture=module.GpuCapture.__new__(module.GpuCapture)
        capture.mode=mode;capture.gl=object();capture.x=object()
        capture.dpy=1;capture.window=2;capture.source_size=(1919,1079)
        capture.width=1920;capture.height=1080;capture.fbos=[3,4]
        capture.frames=0;capture.release_fences=0;capture.display=5
        capture.connection=Mock();capture.create_sync=Mock(return_value=6)
        capture.destroy_sync=Mock()
        read,write=os.pipe();capture.dup_fence=lambda *_:os.dup(read)
        calls=[]
        def fake_fn(lib,name,result,args):
            def call(*values):
                calls.append((name,values))
                return 1 if name=='XGetImage' else 0
            return call
        try:
            with patch.object(module,'fn',side_effect=fake_fn),patch.object(module,'receive_release',return_value=b'K\0\0\0'):
                capture.frame()
            self.assertEqual(capture.frames,1);self.assertEqual(capture.release_fences,1)
            capture.connection.sendmsg.assert_called_once()
            capture.destroy_sync.assert_called_once()
            return [name for name,args in calls]
        finally:os.close(read);os.close(write)

    def test_solid_omits_x11_read_and_blit_but_keeps_handoff(self):
        calls=self.exercise('solid')
        self.assertIn('glClear',calls);self.assertIn('glFlush',calls)
        self.assertNotIn('XGetImage',calls);self.assertNotIn('glBlitFramebuffer',calls)

    def test_generated_mode_omits_per_frame_x11_calls(self):
        calls=self.exercise('generated')
        self.assertIn('glClear',calls)
        self.assertNotIn('XGetImage',calls);self.assertNotIn('glBlitFramebuffer',calls)

    def test_normal_mode_keeps_source_copy(self):
        calls=self.exercise('composite')
        self.assertIn('XGetImage',calls);self.assertIn('glBlitFramebuffer',calls)
        self.assertNotIn('glClear',calls)

if __name__=='__main__':unittest.main()
