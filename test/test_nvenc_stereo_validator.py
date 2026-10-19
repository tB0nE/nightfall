"""Offline negative tests for the diagnostic H.264 output checker."""
import unittest

from check_nvenc_stereo import validate


class StereoValidatorTests(unittest.TestCase):
    @staticmethod
    def pattern(*, swap_eyes=False, flip_y=False):
        data = bytearray()
        for y in range(256):
            y = 255 - y if flip_y else y
            for x in range(512):
                if swap_eyes:
                    x = (x + 256) % 512
                rgb = (255 if x < 128 else 128, 64, 0) if x < 256 else (0, 64, 255 if y < 128 else 128)
                data.extend(rgb)
        return bytes(data) * 5

    def test_correct(self):
        validate(self.pattern())

    def test_larger_profile(self):
        small = self.pattern()[:512*256*3]
        rows = []
        for row in range(256):
            start = row*512*3
            line = b"".join(small[start+x:start+x+3]*2 for x in range(0,512*3,3))
            rows.extend((line,line))
        validate(b"".join(rows),frames=1,eye_size=512)
        with self.assertRaises(ValueError):
            validate(b"".join(rows),frames=1,eye_size=256)

    def test_unbounded_profile_rejected(self):
        with self.assertRaises(ValueError):
            validate(b"",frames=1,eye_size=1024)

    def test_swapped_eyes_rejected(self):
        with self.assertRaises(ValueError):
            validate(self.pattern(swap_eyes=True))

    def test_vertical_flip_rejected(self):
        with self.assertRaises(ValueError):
            validate(self.pattern(flip_y=True))

    def test_truncated_rejected(self):
        with self.assertRaises(ValueError):
            validate(self.pattern()[:-1])

    def test_black_rejected(self):
        with self.assertRaises(ValueError):
            validate(bytes(512 * 256 * 3 * 5))

    def test_single_final_frame(self):
        frame = bytearray(self.pattern()[:512 * 256 * 3])
        frame[1::3] = bytes([255]) * (512 * 256)
        validate(bytes(frame), frames=1, green=255)

    def test_stale_green_rejected(self):
        with self.assertRaises(ValueError):
            validate(self.pattern()[:512 * 256 * 3], frames=1, green=255)

    def test_changing_sequence(self):
        first = self.pattern()[:512 * 256 * 3]
        second = bytearray(first)
        second[1::3] = bytes([137]) * (512 * 256)
        validate(first + second, frames=2, greens=[64, 137])
        for bad in (first + first, bytes(second) + first):
            with self.assertRaises(ValueError):
                validate(bad, frames=2, greens=[64, 137])

    def test_missing_marker_rejected(self):
        with self.assertRaises(ValueError):
            validate(self.pattern(), frames=5, greens=[64])


if __name__ == "__main__":
    unittest.main()
