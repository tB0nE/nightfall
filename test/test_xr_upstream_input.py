from unittest import TestCase, main
from check_xr_upstream_input import inspect_input


def row(x, z, yaw=0, active=1, left=0):
    return (f'UPSTREAM_INPUT left_active={active} right_active={active} '
            f'left={left},0 right={x},0.2500 origin=0,0,{z} yaw={yaw}\n')


class UpstreamInputTests(TestCase):
    def test_synthetic_actions_and_movement(self):
        result = inspect_input(row(-.2, 0)+row(.2, -.1), synthetic=True)
        self.assertTrue(result['locomotion_changed'])

    def test_no_movement_is_not_synthetic_pass(self):
        with self.assertRaises(RuntimeError):
            inspect_input(row(.2, 0)*2, synthetic=True)

    def test_unbound_left_action_is_rejected(self):
        with self.assertRaises(RuntimeError):
            inspect_input(row(.2, 0, left=.2)*2, synthetic=False)

    def test_inactive_trackers_are_rejected(self):
        with self.assertRaises(RuntimeError):
            inspect_input(row(.2, 0, active=0)*2, synthetic=False)

    def test_hardware_observation_does_not_invent_interaction(self):
        result = inspect_input(row(0, 0)*2, synthetic=False)
        self.assertFalse(result['locomotion_changed'])
        self.assertFalse(result['synthetic_assertions'])

    def test_hardware_allows_resting_left_controller(self):
        log = (row(.2, 0)+row(.2, -.1)).replace('left_active=1', 'left_active=0')
        result = inspect_input(log, synthetic=False)
        self.assertFalse(result['both_trackers_active'])
        self.assertTrue(result['locomotion_changed'])
        with self.assertRaises(RuntimeError):
            inspect_input(log, synthetic=True)


if __name__ == '__main__':
    main()
