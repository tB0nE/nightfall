from unittest.mock import patch
import tempfile
import unittest
from pathlib import Path
from xr_runtime_registration import acquire, release


class RuntimeRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.target = self.root / 'meteor.json'
        self.target.write_text('{}')
        self.destination = self.root / 'config/active_runtime.json'
        self.journal = self.root / 'private/lease.json'

    def acquire(self):
        acquire(self.destination, self.target, self.journal)

    def test_absent_entry_and_repeated_cleanup(self):
        self.acquire()
        self.assertEqual(self.destination.resolve(), self.target)
        self.assertTrue(release(self.journal))
        self.assertFalse(self.destination.exists())
        self.assertTrue(release(self.journal))

    def test_restore_regular_file_after_restart(self):
        self.destination.parent.mkdir()
        self.destination.write_bytes(b'original configuration')
        self.acquire()
        self.assertTrue(release(self.journal))
        self.assertEqual(self.destination.read_bytes(), b'original configuration')

    def test_preserve_dangling_relative_symlink(self):
        self.destination.parent.mkdir()
        self.destination.symlink_to('../missing-wivrn.json')
        self.acquire()
        self.assertTrue(release(self.journal))
        self.assertEqual(str(self.destination.readlink()), '../missing-wivrn.json')

    def test_foreign_replacement_preserved_with_backup(self):
        self.destination.parent.mkdir()
        self.destination.write_text('original')
        self.acquire()
        self.destination.unlink()
        self.destination.write_text('new user selection')
        self.assertFalse(release(self.journal))
        self.assertEqual(self.destination.read_text(), 'new user selection')
        self.assertTrue(self.journal.exists())
        self.assertEqual(len(list(self.destination.parent.glob('*backup*'))), 1)

    def test_duplicate_acquisition_refused(self):
        self.acquire()
        with self.assertRaises(FileExistsError):
            self.acquire()
        self.assertTrue(release(self.journal))

    def test_failure_after_backup_restores_original(self):
        self.destination.parent.mkdir()
        self.destination.write_text('original')
        original_replace = Path.replace

        def fail_install(path, target):
            if '.meteor-new-' in path.name:
                raise OSError('simulated installation failure')
            return original_replace(path, target)

        with patch.object(Path, 'replace', fail_install):
            with self.assertRaises(OSError):
                self.acquire()
        self.assertEqual(self.destination.read_text(), 'original')
        self.assertFalse(self.journal.exists())

    def test_crash_between_backup_and_install_recovers(self):
        import json
        self.destination.parent.mkdir()
        self.destination.write_text('original')
        self.acquire()
        record = json.loads(self.journal.read_text())
        self.destination.rename(record['temporary'])
        self.assertTrue(release(self.journal))
        self.assertEqual(self.destination.read_text(), 'original')
        self.assertFalse(Path(record['temporary']).exists())

    def test_missing_target_leaves_configuration_untouched(self):
        self.target.unlink()
        with self.assertRaises(ValueError):
            self.acquire()
        self.assertFalse(self.journal.exists())


if __name__ == '__main__':
    unittest.main()
