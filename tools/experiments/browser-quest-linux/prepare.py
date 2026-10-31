#!/usr/bin/python3
"""Fetch official ARM64 Ubuntu/Chrome and Android PRoot into ignored local cache."""
import copy
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

WORK = Path(__file__).resolve().parents[3] / '.build-cache/browser-quest-linux'
WORK.mkdir(parents=True, exist_ok=True)


def fetch(url, name):
    target = WORK / name
    if not target.exists():
        partial = target.with_name(target.name + '.part')
        with urllib.request.urlopen(url, timeout=60) as src, partial.open('wb') as dst:
            shutil.copyfileobj(src, dst)
        partial.replace(target)
    return target


base = 'https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/'
name = 'ubuntu-base-24.04.5-base-arm64.tar.gz'
rootfs = fetch(base + name, name)
expected = 'a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2'
assert hashlib.sha256(rootfs.read_bytes()).hexdigest() == expected, 'Ubuntu checksum mismatch'
portable = WORK / 'rootfs-portable.tar.gz'
if not portable.exists():
    # Android shell SELinux denies hardlinks. Keep symlinks but duplicate hardlinked files.
    with tarfile.open(rootfs) as src, tarfile.open(portable, 'w:gz', compresslevel=1) as dst:
        for original in src:
            member = copy.copy(original)
            data = src.extractfile(original) if original.isfile() or original.islnk() else None
            if original.islnk():
                member.type, member.linkname = tarfile.REGTYPE, ''
                member.size = src.getmember(original.linkname).size
            dst.addfile(member, data)

repo = 'https://packages.termux.dev/apt/termux-main/'
index = fetch(repo + 'dists/stable/main/binary-aarch64/Packages', 'Packages')
records = {}
unpacked = WORK / 'termux'
for paragraph in index.read_text().split('\n\n'):
    fields = dict(line.split(': ', 1) for line in paragraph.splitlines()
                  if ': ' in line and not line.startswith(' '))
    package = fields.get('Package')
    if package not in ('proot', 'libtalloc', 'libandroid-shmem'):
        continue
    url = repo + fields['Filename']
    deb = fetch(url, Path(fields['Filename']).name)
    assert hashlib.sha256(deb.read_bytes()).hexdigest() == fields['SHA256'], package
    members = subprocess.check_output(['ar', 't', str(deb)], text=True).splitlines()
    member = next(x for x in members if x.startswith('data.tar'))
    data = subprocess.check_output(['ar', 'p', str(deb), member])
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        archive.extractall(unpacked, filter='data')
    records[package] = dict(version=fields['Version'], url=url, sha256=fields['SHA256'])
assert len(records) == 3
for directory in ('bin', 'lib', 'libexec'):
    shutil.copytree(unpacked / 'data/data/com.termux/files/usr' / directory,
                    WORK / 'runtime' / directory, symlinks=False, dirs_exist_ok=True)
chrome = fetch('https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb',
               'google-chrome-arm64.deb')
records['chrome'] = dict(url='https://dl.google.com/linux/direct/google-chrome-stable_current_arm64.deb',
                         sha256=hashlib.sha256(chrome.read_bytes()).hexdigest())
(WORK / 'packages.json').write_text(json.dumps(records, indent=2) + '\n')
print('Prepared', WORK)
