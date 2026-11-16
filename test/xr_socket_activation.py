"""Linux XR socket activation foundation, independent of headset control.

Keep the listening socket open while preparing a session. Never accept/proxy
Monado traffic here: the runtime must receive original connections and their
SCM_RIGHTS descriptors. Caller supplies a bounded async preparation callback;
no application argv is accepted from a socket or headset.
"""
import asyncio
import fcntl
import os
from pathlib import Path
import socket
import stat
import subprocess


class ActivationListener:
    def __init__(self, directory):
        self.directory = Path(directory)
        self.path = self.directory / 'monado_comp_ipc'
        self.listener = None
        self.lock = None
        self.process = None
        self.identity = None
        self.busy = False

    def __enter__(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        meta = self.directory.lstat()
        if not stat.S_ISDIR(meta.st_mode) or meta.st_uid != os.getuid() or meta.st_mode & 0o077:
            raise ValueError('Activation directory must be private and owned by this user')
        if len(os.fsencode(self.path)) >= 108:
            raise ValueError('Activation socket path is too long')
        fd = os.open(self.directory / 'activation.lock',
                     os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        self.lock = os.fdopen(fd, 'r+')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            # Never unlink a pre-existing socket: it might belong to a runtime.
            self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.listener.bind(str(self.path))
            meta = self.path.lstat()
            self.identity = (meta.st_dev, meta.st_ino)
            os.chmod(self.path, 0o600)
            self.listener.listen(8)
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    async def activate(self, prepare, *, timeout=10):
        """Wait for a game, prepare locally, then hand the listener to the child.

        prepare returns (argv, environment). Runtime must support
        METEOR_XR_LISTEN_FD. The deadline covers both waiting and preparation.
        """
        if self.busy or (self.process is not None and self.process.poll() is None):
            raise RuntimeError('An XR activation is already in progress')
        self.busy = True
        loop = asyncio.get_running_loop()
        ready = loop.create_future()

        def readable():
            if not ready.done():
                ready.set_result(None)

        try:
            async def start():
                loop.add_reader(self.listener.fileno(), readable)
                try:
                    await ready
                finally:
                    loop.remove_reader(self.listener.fileno())
                argv, environment = await prepare()
                env = dict(environment)
                env['METEOR_XR_LISTEN_FD'] = str(self.listener.fileno())
                # close_fds preserves only this socket. The session lock stays
                # with the broker, not the runtime or game.
                self.process = subprocess.Popen(argv, env=env, close_fds=True,
                                                pass_fds=(self.listener.fileno(),))
                return self.process
            return await asyncio.wait_for(start(), timeout)
        finally:
            self.busy = False

    def __exit__(self, *_):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        if self.listener is not None:
            self.listener.close()
        try:
            meta = self.path.lstat()
            if (meta.st_dev, meta.st_ino) == self.identity:
                self.path.unlink()
        except FileNotFoundError:
            pass
        if self.lock is not None:
            self.lock.close()
