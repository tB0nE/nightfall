"""Resolve the socket ABI shared by installed Monado client and service.

Old installed bundles retain their legacy socket. New builds stamp the namespace
only after successfully compiling both binaries; no inference from source date.
"""
import json
from pathlib import Path

LEGACY_SOCKET = 'monado_comp_ipc'
ACTIVATION_SOCKET = 'nightfall-meteor/monado_comp_ipc'


def socket_name(root):
    root = Path(root)
    manifest = root / 'xr-runtime/manifest.json'
    if manifest.is_file():
        value = json.loads(manifest.read_text()).get('ipc_socket', LEGACY_SOCKET)
    else:
        stamp = root / '.build-cache/meteor-xr/monado-linux-spike/ipc-socket-name'
        value = stamp.read_text().strip() if stamp.is_file() else LEGACY_SOCKET
    if value not in (LEGACY_SOCKET, ACTIVATION_SOCKET):
        raise ValueError('Unsupported XR IPC socket ABI')
    return value


def socket_path(root, runtime, *, prepare=False):
    path = Path(runtime) / socket_name(root)
    if prepare:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path
