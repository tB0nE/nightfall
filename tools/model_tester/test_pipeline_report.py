import unittest

import numpy as np
from pipeline_report import Renderer, desktop, shader, unpack


class PipelineTests(unittest.TestCase):
    def test_pixel_shuffle(self):
        actual = unpack(np.array([[[[1,2,3,4],[5,6,7,8]]]]), "packed2x2")
        np.testing.assert_array_equal(actual, [[1,2,5,6],[3,4,7,8]])

    def test_invalid_packed_output(self):
        with self.assertRaises(ValueError):
            unpack(np.zeros((1,2,2,1)), "packed2x2")

    def test_shader_extraction(self):
        for name in ("VERTEX_SRC", "UPSAMPLE_FRAGMENT_SRC", "OFFSET_FRAGMENT_SRC", "FRAGMENT_SRC"):
            self.assertIn("void main()", shader(name))
            self.assertIn("#version 430 core", desktop(shader(name)))

    def test_capture_orientation_and_neutral_warp(self):
        renderer = Renderer()
        rgb = np.zeros((32,64,3), np.uint8)
        rgb[:16,:,0] = 255
        rgb[16:,:,2] = 255
        source = renderer.texture(rgb)
        captured, pixels = renderer.draw("capture", (64,32), {"u_video":source}, {})
        self.assertGreater(pixels[0,0,0], 250)
        self.assertGreater(pixels[-1,0,2], 250)
        depth = renderer.texture(np.full((32,64),128,np.uint8))
        final, pixels = renderer.draw("FRAGMENT_SRC", (64,32), {"u_texture":source,"u_depth":depth,"u_offsets":depth}, {"u_disparity":0.,"u_occlusion":0.,"u_eyeIndex":0.,"u_convergence":.5,"u_depthProcessStage":1,"u_stereoMode":0})
        np.testing.assert_array_equal(pixels[:,:,:3],rgb)
        for tex in (source,captured,depth,final):
            tex.release()


if __name__ == "__main__":
    unittest.main()
