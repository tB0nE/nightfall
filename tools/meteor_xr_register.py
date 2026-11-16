#!/usr/bin/env python3
"""Hold a reversible Linux XR registration lease until stdin closes.

Called by the opt-in Meteor activation service, not by games. --check prints a
plan only. It never edits Steam launch options or the Steam environment.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).absolute().parents[1]
sys.path.insert(0, str(ROOT / 'test'))
from xr_runtime_paths import ACTIVATION_SOCKET, socket_name
from xr_runtime_registration import RegistrationGroup


def registration_inputs(root):
    # Immutable installed versions are pinned for the lifetime of this lease;
    # no generated manifest points into an ephemeral AppImage mount.
    from meteor_xr_runtime import validate
    manifest = validate(root)
    if socket_name(root) != ACTIVATION_SOCKET:
        raise ValueError('Install a namespaced activation runtime before registration')
    if manifest.get('openvr_compat') != 'xr-runtime/xrizer':
        raise ValueError('Automatic registration requires bundled xrizer')
    library = (root/'.build-cache/meteor-xr/monado-linux-spike/capture-build/src/xrt/targets/openxr/libopenxr_monado.so').resolve(strict=True)
    xrizer = (root/'xr-runtime/xrizer').resolve(strict=True)
    return library, xrizer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    root = args.root.absolute()
    library, xrizer = registration_inputs(root)
    config = Path(os.environ.get('XDG_CONFIG_HOME', Path.home()/'.config'))
    state = root/'.build-cache/meteor-xr/runtime-registration'
    if args.check:
        print(json.dumps(dict(ready=True, ipc_socket=ACTIVATION_SOCKET,
                              config=str(config), library=str(library), xrizer=str(xrizer))))
        return
    # Block upgrades while the registered library is in use, even between games.
    import fcntl
    lock_path = root/'.build-cache/meteor-xr/runtime-registration.lock'
    with lock_path.open('a') as install_lock:
        fcntl.flock(install_lock, fcntl.LOCK_EX)
        with RegistrationGroup(config, state) as group:
            manifest = state/('openxr-'+uuid.uuid4().hex+'.json')
            manifest.write_text(json.dumps(dict(file_format_version='1.0.0',
                runtime=dict(name='Nightfall Meteor',library_path=str(library)))))
            group.register(manifest, xrizer)
            print(json.dumps(dict(ready=True,ipc_socket=ACTIVATION_SOCKET)), flush=True)
            # The owned stdin pipe closes on Meteor shutdown/crash. No
            # timing loop, rendering, GPU work or game process is needed.
            sys.stdin.buffer.read()
        if group.conflicts:
            print('Runtime selection changed externally; registration backup retained',file=sys.stderr)


if __name__ == '__main__':
    main()
