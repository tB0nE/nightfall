"""An APK must never export with an old or unverified patched engine binary."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
VERSIONS = REPO / "tools/build_support/native_xr_versions.sh"


class RuntimeStampTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(REPO / "patches", self.root / "patches")
        self.runtime = self.root / "android_release_arm64.so"
        self.runtime.write_bytes(b"release-runtime-fixture")
        self.stamp = Path(str(self.runtime) + ".build-stamp")
        self.run_shell('nightfall_runtime_build_stamp "$2" "$3" > "$3.build-stamp"', check=True)

    def run_shell(self, script, **kwargs):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; ' + script, "bash",
             str(VERSIONS), str(self.root), str(self.runtime)],
            capture_output=True, text=True, **kwargs,
        )

    def valid(self):
        return self.run_shell('nightfall_validate_runtime_build "$2" "$3"').returncode == 0

    def test_unchanged_build_is_accepted(self):
        self.assertTrue(self.valid())

    def test_updated_render_patch_rejects_cached_binary(self):
        patch = self.root / "patches/godot-4.7-gles3-render-target-override.patch"
        patch.write_text(patch.read_text() + "\nupdated patch\n")
        self.assertFalse(self.valid())

    def test_replaced_runtime_is_rejected(self):
        self.runtime.write_bytes(b"older-runtime-without-render-fix")
        self.assertFalse(self.valid())

    def test_source_stamp_does_not_certify_a_binary(self):
        self.stamp.unlink()
        (self.root / "godot-patches.sha256").write_text("sources updated")
        self.assertFalse(self.valid())


if __name__ == "__main__":
    unittest.main()
