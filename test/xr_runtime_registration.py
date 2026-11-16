"""Reversible runtime registration primitive; caller supplies explicit paths.

Used by the opt-in authenticated registration helper. Atomic symlink replacement
and inode/content ownership
prevent cleanup from overwriting a later selection by another VR tool. A journal
survives a process crash; the caller must hold its session lock during recovery.
"""
import hashlib
import json
import os
from pathlib import Path
import uuid


def _identity(path):
    try:
        value = path.lstat()
        return [value.st_dev, value.st_ino]
    except FileNotFoundError:
        return None


def _save(journal, record):
    temporary = journal.with_name(journal.name + '.tmp')
    with temporary.open('w', encoding='utf-8') as output:
        json.dump(record, output)
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(journal)


def acquire(destination, target, journal):
    """Acquire one entry. Journal directory must be private and caller-locked."""
    destination, target, journal = map(Path, (destination, target, journal))
    if not all(path.is_absolute() for path in (destination, target, journal)):
        raise ValueError('Registration paths must be absolute')
    if not target.is_file():
        raise ValueError('Registration target must exist')
    if journal.exists():
        raise FileExistsError('Recover the existing registration lease first')
    destination.parent.mkdir(parents=True, exist_ok=True)
    journal.parent.mkdir(parents=True, exist_ok=True)
    token = uuid.uuid4().hex
    backup = destination.with_name(destination.name + '.meteor-backup-' + token)
    temporary = destination.with_name(destination.name + '.meteor-new-' + token)
    if destination.is_dir() and not destination.is_symlink():
        raise ValueError('Refusing to replace a directory')
    original = _identity(destination)
    temporary.symlink_to(target)
    record = dict(destination=str(destination), backup=str(backup),
                  temporary=str(temporary), original=original,
                  owned=_identity(temporary), target=str(target),
                  digest=hashlib.sha256(target.read_bytes()).hexdigest())
    # Persist ownership before any mutation of the user's entry.
    _save(journal, record)
    try:
        if original is not None:
            destination.rename(backup)
        temporary.replace(destination)
    except BaseException:
        release(journal)
        raise


def release(journal):
    """Restore own entry only; retain a backup if another tool changed it.

    Returns False for a conflict; its journal/backup remain available for review.
    """
    journal = Path(journal)
    if not journal.exists():
        return True
    record = json.loads(journal.read_text())
    destination, backup, temporary = (Path(record[key]) for key in
                                      ('destination', 'backup', 'temporary'))
    current = _identity(destination)
    if current == record['owned']:
        try:
            unchanged = hashlib.sha256(destination.read_bytes()).hexdigest() == record.get('digest')
        except OSError:
            unchanged = False
        if not unchanged:
            return False
        destination.unlink()
        current = None
    if current is None and _identity(backup) is not None:
        backup.rename(destination)
    elif current is not None and current != record['original']:
        return False
    if _identity(temporary) == record['owned']:
        temporary.unlink()
    journal.unlink()
    return True


class RegistrationGroup:
    """Locked, recoverable OpenXR/OpenVR registration transaction.

    No live paths are inferred: the caller supplies config/state roots. A crash
    releases the OS lock; the next owner restores journaled entries first.
    Conflicting user/VR-tool edits are preserved and block re-registration.
    """
    ENTRIES = ('openxr', 'openxr-x86_64', 'openvr')

    def __init__(self, config_home, state_directory):
        self.config = Path(config_home)
        self.state = Path(state_directory)
        self.lock = None
        self.conflicts = []

    def __enter__(self):
        import fcntl
        import stat
        if not self.config.is_absolute() or not self.state.is_absolute():
            raise ValueError('Registration roots must be absolute')
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        meta = self.state.lstat()
        if not stat.S_ISDIR(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o077:
            raise ValueError('Registration state directory must be private and user-owned')
        fd = os.open(self.state / 'owner.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        self.lock = os.fdopen(fd, 'r+')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.restore()
            if self.conflicts:
                raise RuntimeError('Runtime registration changed externally; retained journals: ' + ', '.join(self.conflicts))
        except BaseException:
            self.lock.close()
            self.lock = None
            raise
        return self

    def register(self, manifest, xrizer):
        if self.lock is None:
            raise RuntimeError('Registration group must be locked')
        if any((self.state / (entry + '.lease.json')).exists() for entry in self.ENTRIES):
            raise RuntimeError('This group already has active registration leases')
        manifest, xrizer = Path(manifest), Path(xrizer)
        if not manifest.is_absolute() or not xrizer.is_absolute():
            raise ValueError('Runtime paths must be absolute')
        value = json.loads(manifest.read_text())
        if not isinstance(value, dict) or not isinstance(value.get('runtime'), dict):
            raise ValueError('Invalid OpenXR runtime manifest')
        from xr_local_application import validate_openvr_compat
        validate_openvr_compat(str(xrizer))
        destinations = [self.config/'openxr/1/active_runtime.json',
                        self.config/'openxr/1/active_runtime.x86_64.json',
                        self.config/'openvr/openvrpaths.vrpath']
        registry = destinations[2]
        # Preserve unrelated OpenVR keys and driver configuration. A malformed
        # existing registry fails before either OpenXR selector is changed.
        data = json.loads(registry.read_text()) if registry.exists() else {}
        if not isinstance(data, dict):
            raise ValueError('Existing OpenVR registry is not an object')
        data['runtime'] = [str(xrizer)]
        data.setdefault('version', 1)
        data.setdefault('jsonid', 'vrpathreg')
        candidate = self.state / ('openvr-' + uuid.uuid4().hex + '.json')
        with candidate.open('x') as output:
            json.dump(data, output, indent=2)
        candidate.chmod(0o600)
        targets = [manifest, manifest, candidate]
        try:
            for entry, destination, target in zip(self.ENTRIES, destinations, targets):
                acquire(destination, target, self.state/(entry+'.lease.json'))
        except BaseException:
            self.restore()
            raise

    def restore(self):
        self.conflicts = []
        for entry in reversed(self.ENTRIES):
            journal = self.state/(entry+'.lease.json')
            if not release(journal):
                self.conflicts.append(str(journal))
        # Candidates are retained on conflicts so a user's edits and journal
        # still refer to existing files. Remove only our generated file names.
        if not self.conflicts:
            import re
            for candidate in self.state.iterdir():
                if re.fullmatch(r'(openxr|openvr)-[0-9a-f]{32}\.json', candidate.name):
                    candidate.unlink()

    def __exit__(self, *_):
        try:
            if self.lock is not None:
                self.restore()
        finally:
            if self.lock is not None:
                self.lock.close()
                self.lock = None
