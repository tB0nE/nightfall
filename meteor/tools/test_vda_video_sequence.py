#!/usr/bin/env python3
"""Boundary tests for the independent video reference's history contract."""
import unittest
import numpy as np
from vda_video_sequence import History, thumbnail, HEIGHT, WIDTH, state_shapes


class SequenceContract(unittest.TestCase):
    def test_state_dimensions_match_exported_contracts(self):
        self.assertEqual(state_shapes(518,294), [(777,192)]*2+[(209,384)]*2+[(777,64)]*2+[(3108,64)]*2)
        self.assertEqual(state_shapes(420,238), [(510,192)]*2+[(135,384)]*2+[(510,64)]*2+[(2040,64)]*2)
        with self.assertRaises(ValueError):
            state_shapes(421,238)

    def test_rollover_selects_expected_frame_ages(self):
        history = History()
        stamps = {0: 0}
        self.assertEqual(history.selection(), [0]*31)
        for frame in range(1, 65):
            slot = history.free_slot()
            self.assertNotIn(slot, history.list)
            stamps[slot] = frame
            history.push(slot)
        self.assertEqual(len(history.list), 42)
        self.assertEqual([stamps[s] for s in history.selection()], [0, 24]+list(range(36, 65)))

    def test_reset_never_selects_old_session_slots(self):
        history = History()
        for _ in range(70):
            history.push(history.free_slot())
        reset = History()
        self.assertEqual(reset.selection(), [0]*31)
        self.assertEqual(reset.free_slot(), 1)

    def test_thumbnail_keeps_normalized_channels_and_cut_units(self):
        image = np.empty((3, HEIGHT, WIDTH), np.float32)
        for channel in range(3):
            image[channel] = channel+1
        result = thumbnail(image)
        self.assertEqual(result.shape, (3, 9, 16))
        for channel in range(3):
            np.testing.assert_array_equal(result[channel], channel+1)
        self.assertGreater(float(np.abs(thumbnail(image+1.01)-result).mean()), 1.0)
        self.assertLess(float(np.abs(thumbnail(image+0.99)-result).mean()), 1.0)


if __name__ == "__main__":
    unittest.main()
