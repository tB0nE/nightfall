#!/usr/bin/env python3
"""Record release inputs and optionally package source; never include user state."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]


def digest(path):
    hasher=hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1<<20),b''):
            hasher.update(block)
    return hasher.hexdigest()


def sources(root):
    companion=root.parent/'SOURCE_MANIFEST.json'
    if companion.is_file():
        names=json.loads(companion.read_text())['source_sha256']
    else:
        names = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z',
                                         '--cached', '--others', '--exclude-standard'], stderr=subprocess.DEVNULL).decode().split('\0')
    allowed = ('meteor/', 'tools/build_support/', 'test/', 'extensions/nightfall-xr/include/')
    selected = []
    for name in sorted(set(names)):
        path = root / name
        if not path.is_file() or path.is_symlink() or '__pycache__' in path.parts:
            continue
        if name.startswith(allowed) or name.startswith('tools/meteor_') or name in (
                'LICENSE', 'BUILD.md', 'src/assets/nightfall_icon_v1.png'):
            if path.suffix in ('.pyc', '.so', '.dll', '.apk', '.AppImage', '.keystore', '.jks', '.pem', '.p12') or '.env' in path.name:
                continue
            selected.append(name)
    if (root/'tools/ZipDepth/LICENSE').is_file() and 'tools/ZipDepth/LICENSE' not in selected:
        selected.append('tools/ZipDepth/LICENSE')
    return sorted(selected)


def metadata(root):
    names = sources(root)
    if (root.parent/'SOURCE_MANIFEST.json').is_file():
        info=json.loads((root.parent/'SOURCE_MANIFEST.json').read_text())
        current={name:digest(root/name) for name in names}
        info['working_tree_changes'] = info['working_tree_changes'] or current!=info['source_sha256']
        info['source_sha256']=current
        return info
    return {
        'schema': 1,
        'nightfall_repository': 'https://github.com/tB0nE/nightfall',
        'nightfall_commit': subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip(),
        'working_tree_changes': bool(subprocess.check_output(['git', '-C', str(root), 'status', '--porcelain'])),
        'source_sha256': {name: digest(root/name) for name in names},
        'build_instructions': ['meteor/RELEASE.md', 'meteor/tools/build_appimage.sh',
                               'tools/build_support/build_meteor_xr_bundle.sh'],
    }


def add_tree(archive, source, target):
    for path in sorted(source.rglob('*')):
        if not path.is_file() or path.is_symlink() or any(part in ('.git', '__pycache__', 'target') for part in path.relative_to(source).parts):
            continue
        archive.add(path, arcname=str(Path(target)/path.relative_to(source)), recursive=False)


def package(output, vendor):
    if output.exists():
        raise ValueError('Choose a new source archive path')
    info = metadata(ROOT)
    for component in ('meteor','xrizer'):
        if not list((vendor/component).glob('*/.cargo-checksum.json')):
            raise ValueError('Missing vendored dependencies: '+component)
    partial=output.with_name(output.name+'.partial')
    with tarfile.open(partial, 'w:gz', compresslevel=6) as archive:
        for name in info['source_sha256']:
            archive.add(ROOT/name, arcname='Nightfall/'+name, recursive=False)
        for component, target in [('meteor', 'Nightfall/meteor'), ('xrizer', 'upstream/xrizer')]:
            add_tree(archive, vendor/component, target+'/vendor')
            config = b'[source.crates-io]\nreplace-with = "vendored-sources"\n[source.vendored-sources]\ndirectory = "vendor"\n'
            entry = tarfile.TarInfo(target+'/.cargo/vendor-config.toml')
            entry.size = len(config)
            archive.addfile(entry, io.BytesIO(config))
        for component, source in [('monado', ROOT/'.build-cache/meteor-xr/portable-package/compiled/capture-source'),
                                  ('xrizer', ROOT/'.build-cache/meteor-xr/xrizer')]:
            if not source.is_dir(): raise ValueError('Missing runtime source: '+str(source))
            add_tree(archive, source, 'upstream/'+component)
        ffmpeg = ROOT/'meteor/target/appimage/cargo-target/ffmpeg-build/ffmpeg-8.0.1.tar.xz'
        if not ffmpeg.is_file(): raise ValueError('Missing exact FFmpeg source archive')
        if digest(ffmpeg)!='05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41':
            raise ValueError('FFmpeg source archive checksum mismatch')
        archive.add(ffmpeg, arcname='upstream/'+ffmpeg.name)
        for name, source in [('Eigen', vendor/'eigen'), ('build-notices', vendor/'build-notices')]:
            add_tree(archive, source, 'upstream/'+name)
        add_tree(archive, ROOT/'.build-cache/meteor-xr/WiVRn/external/ffnvcodec', 'upstream/ffnvcodec')
        data = (json.dumps(info, indent=2)+'\n').encode()
        entry = tarfile.TarInfo('SOURCE_MANIFEST.json')
        entry.size = len(data)
        archive.addfile(entry, io.BytesIO(data))
    partial.replace(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--metadata', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--vendor-root', type=Path)
    args = parser.parse_args()
    if args.metadata:
        args.metadata.write_text(json.dumps(metadata(ROOT), indent=2)+'\n')
    if args.archive:
        if not args.vendor_root: parser.error('--archive requires --vendor-root')
        package(args.archive, args.vendor_root)
