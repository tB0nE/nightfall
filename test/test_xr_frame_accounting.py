import unittest
from xr_frame_accounting import match_submitted_frames


class FrameAccountingTests(unittest.TestCase):
    def test_exact(self):
        self.assertEqual(match_submitted_frames([10,20,30],[10,20,30]),[0,1,2])

    def test_skipped_app_frames(self):
        self.assertEqual(match_submitted_frames([10,20,30,40],[20,40],allow_drops=True),[1,3])

    def test_strict_mode_rejects_drops(self):
        with self.assertRaises(ValueError):
            match_submitted_frames([10,20,30],[10,30])

    def test_missing_final_frame(self):
        with self.assertRaises(ValueError):
            match_submitted_frames([10,20,30],[10,20],allow_drops=True)

    def test_unknown_duplicate_and_reordered(self):
        for output in ([10,25,30],[10,10,30],[20,10,30],[],[0,30]):
            with self.subTest(output=output), self.assertRaises(ValueError):
                match_submitted_frames([10,20,30],output,allow_drops=True)

    def test_bad_submissions(self):
        for inputs in ([],[10,10,30],[20,10,30],[0,20,30]):
            with self.subTest(inputs=inputs), self.assertRaises(ValueError):
                match_submitted_frames(inputs,[30],allow_drops=True)


if __name__ == "__main__":
    unittest.main()
