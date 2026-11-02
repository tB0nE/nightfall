#!/usr/bin/python3
"""Kernel abort doesn't need a functioning app bridge or actual hardware."""
from pathlib import Path
import threading
import unittest
from unittest.mock import Mock
from gpu_hang_monitor import GpuHangMonitor

class HangMonitor(unittest.TestCase):
    def test_hang_stops_both_apps_once(self):
        guard=Mock();monitor=GpuHangMonitor(guard,'unused',Path('/unused'))
        monitor._line('kernel: GPU hang detected\n')
        monitor._line('kernel: GPU hang detected\n')
        self.assertTrue(monitor.hang.is_set())
        self.assertEqual([c.args[0] for c in guard.shell.call_args_list],['am force-stop app.nightfall.browserlab','am force-stop app.nightfall.quest'])
        with self.assertRaises(RuntimeError):monitor.check()

    def test_one_cleanup_failure_does_not_skip_other_app(self):
        guard=Mock();guard.shell.side_effect=[TimeoutError(),None]
        monitor=GpuHangMonitor(guard,'unused',Path('/unused'))
        monitor._line('GPU hang detected')
        self.assertEqual(guard.shell.call_count,2)
        self.assertEqual(monitor.error,'TimeoutError')

    def test_unrelated_log_does_not_stop_apps(self):
        guard=Mock();monitor=GpuHangMonitor(guard,'unused',Path('/unused'))
        monitor._line('normal frame completed')
        guard.shell.assert_not_called();self.assertFalse(monitor.hang.is_set())

if __name__=='__main__':unittest.main()
