import unittest
from check_xr_raster_scene import validate_raster_scene


class RasterSmokeTests(unittest.TestCase):
    def test_blank_rejected(self):
        with self.assertRaisesRegex(ValueError,"lacks"):
            validate_raster_scene(bytes(256*256*6*2),256,2)

    def test_truncated_rejected(self):
        with self.assertRaisesRegex(ValueError,"complete"):
            validate_raster_scene(bytes(30),256,2)

    @staticmethod
    def fixture(stereo=True,moving=True):
        frames=[]
        for frame in range(2):
            pixels=bytearray()
            for y in range(256):
                for eye in range(2):
                    offset=(eye*8 if stereo else 0)+(frame*16 if moving else 0)
                    for x in range(256):
                        color=(9,14,23) if y<128 else (56,56,56)
                        if 50+offset<x<110+offset and 65<y<180:
                            color=(200,40,20)
                        pixels.extend(color)
            frames.append(bytes(pixels))
        return b"".join(frames)

    def test_nonblank_moving_stereo_accepted(self):
        validate_raster_scene(self.fixture(),256,2)

    def test_duplicate_eyes_rejected(self):
        with self.assertRaisesRegex(ValueError,"identical"):
            validate_raster_scene(self.fixture(stereo=False),256,2)

    def test_static_rejected(self):
        with self.assertRaisesRegex(ValueError,"static"):
            validate_raster_scene(self.fixture(moving=False),256,2)


if __name__=="__main__":
    unittest.main()
