#!/usr/bin/env python3
"""Install a staged XR runtime into user data, preserving configuration and logs."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
from meteor_xr_runtime import validate


def configure_bundled_xrizer(destination, manifest):
    if manifest.get('openvr_compat') != 'xr-runtime/xrizer':
        return
    cache = destination / '.build-cache/meteor-xr'
    config = cache / 'application.json'
    spec = json.loads(config.read_text())
    previous = spec.get('openvr_compat')
    borrowed = isinstance(previous, str) and previous.startswith('/var/lib/flatpak/app/io.github.wivrn.wivrn/') and previous.endswith('/files/xrizer')
    bundled = str(destination / 'xr-runtime/xrizer')
    if previous is not None and previous != bundled and not borrowed:
        return  # Preserve an explicitly selected alternative compatibility runtime.
    registry = cache / 'openvrpaths.vrpath'
    data = {'config': [str(cache / 'openvr-config')], 'external_drivers': None,
            'jsonid': 'vrpathreg', 'log': [str(cache / 'openvr-logs')],
            'runtime': [bundled], 'version': 1}
    temporary = registry.with_suffix('.installing')
    temporary.write_text(json.dumps(data, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(registry)
    if previous == bundled:
        return
    if borrowed:
        backup = config.with_name('application.before-bundled-xrizer.json')
        if not backup.exists():
            shutil.copy2(config, backup)
    spec['openvr_compat'] = bundled
    temporary = config.with_suffix('.installing')
    temporary.write_text(json.dumps(spec, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(config)


def export_package(source, destination):
    manifest = validate(source)
    destination.mkdir(mode=0o700)
    for name in [*manifest['sha256'], 'xr-runtime/manifest.json']:
        original = source / name
        if not original.resolve().is_relative_to(source.resolve()):
            raise ValueError('XR package file escapes its directory')
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(original, target)
    validate(destination)


def install(source, destination):
    source = source.resolve(strict=True)
    destination = destination.resolve()
    if destination == source or source in destination.parents or destination in source.parents:
        raise ValueError('XR package and installation must be separate directories')
    manifest = validate(source)
    version = hashlib.sha256((source / 'xr-runtime/manifest.json').read_bytes()).hexdigest()
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    cache = destination / '.build-cache/meteor-xr'
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    versions = destination / 'versions'
    versions.mkdir(mode=0o700, exist_ok=True)
    release = versions / version
    with (cache / 'managed-session.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError('Exit the active XR session before installing its runtime') from error
        if not release.exists():
            with tempfile.TemporaryDirectory(prefix='.install-', dir=versions) as temporary:
                stage = Path(temporary) / 'runtime'
                export_package(source, stage)
                stage.rename(release)
        else:
            validate(release)
        links = {
            destination / 'LICENSE': release / 'LICENSE',
            destination / 'tools': release / 'tools',
            destination / 'test': release / 'test',
            cache / 'monado-linux-spike': release / '.build-cache/meteor-xr/monado-linux-spike',
            destination / 'xr-runtime': release / 'xr-runtime',
        }
        for path in links:
            if path.exists() and not path.is_symlink():
                raise ValueError(f'Refusing to replace unmanaged XR directory: {path}')
        config = cache / 'application.json'
        if not config.exists():
            with config.open('x') as file:
                json.dump({'argv': ['/usr/bin/false'], 'cwd': '/', 'launch': 'steam',
                           'steam_app_id': '*', 'steam_runtime': True}, file, indent=2)
            config.chmod(0o600)
        previous = {}
        try:
            for path, target in links.items():
                previous[path] = os.readlink(path) if path.is_symlink() else None
                temporary = path.with_name(path.name + '.installing')
                temporary.unlink(missing_ok=True)
                temporary.symlink_to(os.path.relpath(target, path.parent), target_is_directory=True)
                temporary.replace(path)
            validate(destination)
            configure_bundled_xrizer(destination, manifest)
        except BaseException:
            for path, target in reversed(list(previous.items())):
                path.unlink(missing_ok=True)
                if target is not None:
                    path.symlink_to(target, target_is_directory=True)
            raise
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    default = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share')) / 'nightfall-meteor/xr'
    parser.add_argument('--destination', type=Path, default=default)
    parser.add_argument('--export', type=Path, help='Copy only verified package files, excluding local state')
    args = parser.parse_args()
    if args.export is not None:
        export_package(args.source.resolve(), args.export)
        print(f'Exported XR package: {args.export}')
        return
    print(f'Installed XR runtime: {install(args.source, args.destination)}')
    print('No headset authorization, Steam launch options or running services were changed.')


if __name__ == '__main__':
    main()
