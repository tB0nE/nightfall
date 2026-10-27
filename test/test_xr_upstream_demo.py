import tempfile
from pathlib import Path
from unittest import TestCase, main
from unittest.mock import patch

from prepare_xr_upstream_demo import PIN, prepare


class UpstreamStagingTests(TestCase):
    def test_staging_preserves_source_and_is_repeatable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / '.build-cache/meteor-xr/godot-demo-projects/xr/openxr_origin_centric_movement'
            source.mkdir(parents=True)
            config = '[rendering]\nrenderer/rendering_method="gl_compatibility"\n[xr]\n'
            player = 'character_body.velocity += get_gravity() * delta\n'
            (source / 'project.godot').write_text(config)
            (source / 'player.gd').write_text(player)
            fixtures = root / 'test/fixtures'
            (fixtures / 'meteor_xr_godot').mkdir(parents=True)
            (fixtures / 'meteor_xr_godot/main.gd').write_text('extends Node3D\n')
            (fixtures / 'meteor_xr_upstream_monitor.gd').write_text('extends Node3D\n')
            with patch('prepare_xr_upstream_demo.subprocess.check_output', return_value=PIN+'\n'):
                destination = prepare(root)
                prepare(root)
            self.assertEqual((source / 'project.godot').read_text(), config)
            self.assertEqual((source / 'player.gd').read_text(), player)
            self.assertEqual((destination / 'project.godot').read_text().count('[autoload]'), 1)
            self.assertIn('character_body.get_gravity()', (destination / 'player.gd').read_text())

    def test_unreviewed_revision_rejected(self):
        with patch('prepare_xr_upstream_demo.subprocess.check_output', return_value='wrong\n'):
            with self.assertRaisesRegex(RuntimeError, 'revision'):
                prepare(Path('/unused'))


if __name__ == '__main__':
    main()
