"""Journal/lifecycle tests without touching the real desktop or D-Bus."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
sys.dont_write_bytecode = True
from unittest.mock import patch

class BackgroundTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        with patch.dict(os.environ, XDG_STATE_HOME=self.temp.name):
            spec = importlib.util.spec_from_file_location('background', Path(__file__).parents[1] / 'meteor/scripts/host_background.py')
            self.m = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.m)
        self.addCleanup(self.m.lock.close)
        self.desktop = {'picture-uri': "'original'", 'picture-uri-dark': "'original-dark'", 'picture-options': "'zoom'", 'primary-color': "'#123456'", 'secondary-color': "'#123456'", 'color-shading-type': "'solid'"}
        self.original = self.desktop.copy()
        self.addCleanup(patch.stopall)
        patch.object(self.m, 'snapshot', lambda backend: self.desktop.copy()).start()
        patch.object(self.m, 'apply', lambda backend, state: self.desktop.update(state)).start()
        patch.dict(os.environ, XDG_CURRENT_DESKTOP='GNOME').start()

    def change(self, color, owner='one'):
        with patch.object(sys, 'argv', ['helper', color, owner]): self.m.main()

    def test_change_restore_and_no_journal_before_mutation(self):
        def apply(backend, state):
            self.assertTrue(self.m.JOURNAL.exists())
            self.desktop.update(state)
        with patch.object(self.m, 'apply', apply): self.change('green')
        self.assertEqual(self.desktop['primary-color'], "'#00ff00'")
        self.change('off')
        self.assertEqual(self.desktop, self.original)
        self.assertFalse(self.m.JOURNAL.exists())

    def test_crash_recovery_and_colour_changes_preserve_original(self):
        self.change('green'); self.change('blue')
        self.change('off', '') # startup recovery, regardless of previous lease
        self.assertEqual(self.desktop, self.original)

    def test_user_wallpaper_change_preserved(self):
        self.change('green')
        self.desktop['picture-uri'] = "'user-picked'"
        self.change('off')
        self.assertEqual(self.desktop['picture-uri'], "'user-picked'")
        self.assertEqual(self.desktop['primary-color'], self.original['primary-color'])

    def test_old_disconnect_cannot_restore_new_lease(self):
        self.change('green', 'one'); self.change('blue', 'two')
        self.change('off', 'one')
        self.assertEqual(self.desktop['primary-color'], "'#0000ff'")
        self.change('off', 'two')
        self.assertEqual(self.desktop, self.original)

    def test_failed_change_restores_partial_mutation(self):
        calls = []
        def apply(backend, state):
            calls.append(state)
            if len(calls) == 1:
                self.desktop['picture-uri'] = state['picture-uri']
                raise RuntimeError('failed')
            self.desktop.update(state)
        with patch.object(self.m, 'apply', apply):
            with self.assertRaises(RuntimeError): self.change('green')
        self.assertEqual(self.desktop, self.original)

    def test_unsupported_desktop_unchanged(self):
        with patch.dict(os.environ, XDG_CURRENT_DESKTOP='unknown'):
            with self.assertRaises(RuntimeError): self.change('green')
        self.assertEqual(self.desktop, self.original)
        self.assertFalse(self.m.JOURNAL.exists())

if __name__ == '__main__': unittest.main()
