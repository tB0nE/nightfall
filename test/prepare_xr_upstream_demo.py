"""Stage a pinned upstream app without modifying its source checkout."""
from pathlib import Path
import shutil
import subprocess

PIN = "b761b4cd5718a7118f2c95eb55f181d0a5f004f1"


def prepare(root):
    checkout = root / '.build-cache/meteor-xr/godot-demo-projects'
    revision = subprocess.check_output(
        ['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != PIN:
        raise RuntimeError('Unexpected upstream demo revision; review before updating pin')
    destination = root / '.build-cache/meteor-xr/upstream-movement-demo'
    source = checkout / 'xr/openxr_origin_centric_movement'
    shutil.copytree(source, destination, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('.godot'))
    # Keep upstream input bindings and scene intact. Only the renderer,
    # unsupported optional depth submission and diagnostic autoload are configured.
    config = destination / 'project.godot'
    text = config.read_text().replace('"gl_compatibility"', '"mobile"')
    text = text.replace('[xr]', '[xr]\nopenxr/submit_depth_buffer=false')
    text += '\n[autoload]\nMeteorDiagnostic="*res://meteor_diagnostic.gd"\n'
    config.write_text(text)
    player = destination / 'player.gd'
    code = player.read_text()
    old = 'character_body.velocity += get_gravity() * delta'
    if code.count(old) != 1:
        raise RuntimeError('Upstream gravity fix no longer applies; review source')
    player.write_text(code.replace(old,
        'character_body.velocity += character_body.get_gravity() * delta'))
    shutil.copyfile(root / 'test/fixtures/meteor_xr_godot/main.gd',
                    destination / 'meteor_diagnostic_base.gd')
    shutil.copyfile(root / 'test/fixtures/meteor_xr_upstream_monitor.gd',
                    destination / 'meteor_diagnostic.gd')
    return destination
