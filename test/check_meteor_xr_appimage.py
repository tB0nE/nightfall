"""Isolated packaged-host checks. No GPU/game or headset is started here."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
from run_meteor_xr_coexistence import run_case


def run(appimage, client, root):
    root.mkdir(mode=0o700)  # Keep diagnostics; never overwrite another run.
    artifact = root / appimage.name
    shutil.copy2(appimage, artifact)
    artifact.chmod(0o755)
    env = dict(os.environ)
    for name in ('APPIMAGE', 'APPDIR', 'ARGV0', 'OWD'):
        env.pop(name, None)
    for kind in ('CONFIG', 'DATA', 'CACHE', 'STATE'):
        env[f'XDG_{kind}_HOME'] = str(root / kind.lower())
    env.update(APPIMAGE_EXTRACT_AND_RUN='1', PYTHONDONTWRITEBYTECODE='1')

    def command(args, label):
        result = subprocess.run(args, cwd=root, env=env, capture_output=True, text=True, timeout=90)
        (root / (label + '.log')).write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f'{label} failed: ' + (result.stdout + result.stderr)[-5000:])
        return result.stdout

    help_text = command([str(artifact), '--help'], 'help')
    if '--install-xr-runtime' not in help_text: raise RuntimeError('Stale or incorrect Meteor binary')
    command([str(artifact), '--install-xr-runtime'], 'install')
    user_config = root / 'config/nightfall-meteor/meteor.toml'
    user_config.parent.mkdir(parents=True, exist_ok=True)
    before = '# Keep my settings\nsunshine_host = "127.0.0.1"\n[xr]\nenabled = false # user preference\n'
    user_config.write_text(before)
    command([str(artifact), '--enable-xr'], 'enable-xr')
    import tomllib
    enabled_text = user_config.read_text()
    if not tomllib.loads(enabled_text)['xr']['enabled'] or '# Keep my settings' not in enabled_text:
        raise RuntimeError('PCVR setup did not enable XR while preserving existing comments')
    if user_config.with_suffix('.before-pcvr-setup.toml').read_text() != before:
        raise RuntimeError('PCVR setup did not retain the original settings backup')
    installed = root / 'data/nightfall-meteor/xr'
    command(['/usr/bin/python3', str(installed / 'tools/meteor_xr_runtime.py'), '--check'], 'installed-check')
    config = installed / '.build-cache/meteor-xr/application.json'
    specification = json.loads(config.read_text())
    expected_compat = installed / 'xr-runtime/xrizer'
    if specification.get('openvr_compat') != str(expected_compat):
        raise RuntimeError('Fresh runtime installation did not select bundled xrizer')
    for name in ('bin/linux64/vrclient.so', 'LICENSE', 'DEPENDENCY_NOTICES.txt', 'UPSTREAM_REVISION'):
        if not (expected_compat / name).is_file():
            raise RuntimeError('Missing bundled xrizer input: ' + name)
    registry = json.loads((config.parent / 'openvrpaths.vrpath').read_text())
    if registry.get('runtime') != [str(expected_compat)]:
        raise RuntimeError('Missing private OpenVR runtime registry')
    options = command(['/usr/bin/python3', str(installed / 'tools/meteor_xr.py'),
                       'steam-options', '--app-id', '546560'], 'steam-options')
    if str(installed / 'tools/meteor_xr.py') not in options:
        raise RuntimeError('Steam wrapper did not retain its installed location')
    command([str(artifact), '--appimage-extract'], 'extract')
    appdir = root / 'squashfs-root'
    models = appdir / 'usr/share/nightfall-meteor/models'
    for model in ('zipdepth_wide_512x288', 'zipdepth_edgepad_256'):
        for extension in ('param', 'bin'):
            if not (models / f'{model}.ncnn.{extension}').is_file(): raise RuntimeError('Missing bundled EdgePad model')
    if any(models.glob('vda_vulkan_*')):
        raise RuntimeError('Default package unexpectedly includes optional VDA exports')
    bundle = appdir / 'usr/share/nightfall-meteor/xr-bundle'
    if (bundle / '.build-cache/meteor-xr/application.json').exists():
        raise RuntimeError('Local application configuration leaked into the package')
    binary = appdir / 'usr/bin/nightfall-meteor'
    for mode in ('installed', 'installed_bind_failure', 'disabled', 'setup'):
        run_case(binary, client, mode, signal.SIGTERM, installed, root / "cases")
    report = {'appimage': artifact.name, 'bytes': artifact.stat().st_size,
              'checks': ['AppImage help', 'bundled runtime installation', 'installed checksums',
                         'PCVR setup command and preserved configuration',
                         'independent bundled xrizer and notices', 'private OpenVR registry',
                         'stable Steam wrapper', 'EdgePad 512/256 assets', 'local state exclusion',
                         'configured XR discovery/authentication', 'proxy forwarding',
                         'XR bind failure isolation', 'XR-disabled startup', 'clean shutdown',
                         'tray PCVR setup, automatic restart and rediscovery'],
              'installed_runtime': str(installed), 'gpu_game_headset_tested': False}
    (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('appimage', type=Path)
    parser.add_argument('control_client', type=Path)
    parser.add_argument('--work-dir', type=Path, required=True, help='New isolated output directory')
    args = parser.parse_args()
    run(args.appimage.resolve(), args.control_client.resolve(), args.work_dir.resolve())
