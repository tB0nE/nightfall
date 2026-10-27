import copy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import audit_meteor_xr_runtime as audit


class AuditTests(unittest.TestCase):
    def report(self, entries):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in entries:
                (root / name).write_bytes(b'\x7fELFfixture')
            with patch.object(audit, 'validate', return_value={'sha256': dict.fromkeys(entries)}), \
                 patch.object(audit, 'inspect', side_effect=lambda path: entries[path.name]):
                return audit.audit(root)

    def binary(self, **values):
        entry = {'needed': ['libc.so.6'], 'soname': None, 'search_paths': [],
                 'glibc': '2.34', 'glibcxx': '3.4.29', 'x86_64': True}
        return dict(entry, **values)

    def test_newer_build_host_and_unbundled_library_rejected(self):
        report = self.report({'service': self.binary(glibc='2.38', needed=['libc.so.6', 'libcjson.so.1'])})
        self.assertFalse(report['static_audit_passed'])
        self.assertEqual(report['missing_bundle_libraries'], ['libcjson.so.1'])
        self.assertEqual(len(report['errors']), 2)

    def test_baseline_build_with_explicit_private_dependency_passes(self):
        report = self.report({'service': self.binary(needed=['libc.so.6', 'libcjson.so.1']),
                              'json': self.binary(soname='libcjson.so.1')})
        self.assertTrue(report['static_audit_passed'])
        self.assertIn('libcuda.so.1', report['dynamic_driver_dependencies'])

    def test_checkout_search_paths_and_wrong_architecture_rejected(self):
        report = self.report({'service': self.binary(search_paths=['/developer/build'], x86_64=False)})
        self.assertEqual(len(report['errors']), 2)
        self.assertFalse(report['static_audit_passed'])

    def test_readelf_parser_retains_runtime_requirements(self):
        output = '''Machine: Advanced Micro Devices X86-64
 (NEEDED) Shared library: [libvulkan.so.1]
 (SONAME) Library soname: [libfixture.so.1]
 (RUNPATH) Library runpath: [$ORIGIN]
 GLIBC_2.34 GLIBC_2.9 GLIBCXX_3.4.29
'''
        with patch.object(audit.subprocess, 'check_output', return_value=output):
            result = audit.inspect(Path('fixture'))
        self.assertEqual(result['glibc'], '2.34')
        self.assertEqual(result['needed'], ['libvulkan.so.1'])
        self.assertEqual(result['soname'], 'libfixture.so.1')


if __name__ == '__main__':
    unittest.main()
