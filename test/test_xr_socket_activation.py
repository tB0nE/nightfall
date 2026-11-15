import array
import asyncio
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

from xr_socket_activation import ActivationListener


class SocketActivationTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='nf-activation-build-')
        cls.native = Path(cls.build.name) / 'receiver'
        source = Path(cls.build.name) / 'receiver.c'
        source.write_text(r'''
#include "meteor_xr_listen_fd.h"
#include <stdio.h>
#include <string.h>
int main(void) {
    int listener = meteor_xr_listen_fd(getenv("METEOR_XR_LISTEN_FD"));
    if (listener < 0) return 2;
    int client = accept(listener, NULL, NULL);
    if (client < 0) return 3;
    char byte;
    struct iovec io = {.iov_base=&byte, .iov_len=1};
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control;
    struct msghdr message = {0};
    message.msg_iov = &io; message.msg_iovlen = 1;
    message.msg_control = control.bytes; message.msg_controllen = sizeof(control);
    if (recvmsg(client, &message, 0) != 1) return 4;
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    if (!header || header->cmsg_type != SCM_RIGHTS) return 5;
    int received; memcpy(&received, CMSG_DATA(header), sizeof(received));
    char data[32]; ssize_t length = read(received, data, sizeof(data));
    if (length <= 0 || send(client, data, (size_t)length, 0) != length) return 6;
    close(received); close(client); close(listener);
    return 0;
}
''')
        subprocess.run(['cc', '-D_GNU_SOURCE', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-I', str(Path(__file__).parent), str(source), '-o', str(cls.native)],
                       check=True, timeout=15)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='nf-activation-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / 'runtime'

    async def test_original_connection_and_shared_memory_fd_survive_handoff(self):
        for _ in range(2):  # Independent activation, teardown, and re-activation.
            with ActivationListener(self.directory) as broker:
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.addCleanup(client.close)
                client.settimeout(2)
                client.connect(str(broker.path))
                with tempfile.TemporaryFile() as shared:
                    shared.write(b'original shared memory'); shared.seek(0)
                    client.sendmsg([b'x'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                            array.array('i', [shared.fileno()]))])
                    calls = []
                    async def prepare():
                        calls.append('prepared')
                        await asyncio.sleep(0.01)
                        return [str(self.native)], dict(os.environ)
                    child = await broker.activate(prepare, timeout=2)
                    result = await asyncio.to_thread(client.recv, 32)
                    self.assertEqual(result, b'original shared memory')
                    self.assertEqual(await asyncio.to_thread(child.wait, 2), 0)
                    self.assertEqual(calls, ['prepared'])
                client.close()
            self.assertFalse(broker.path.exists())

    async def test_idle_timeout_does_not_prepare_or_spawn(self):
        with ActivationListener(self.directory) as broker:
            async def forbidden():
                self.fail('Idle listener started a runtime')
            with self.assertRaises(asyncio.TimeoutError):
                await broker.activate(forbidden, timeout=0.02)
            self.assertIsNone(broker.process)

    async def test_prepare_timeout_cancels_before_spawn(self):
        with ActivationListener(self.directory) as broker:
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(broker.path))
                cancelled = []
                async def prepare():
                    try:
                        await asyncio.sleep(10)
                    finally:
                        cancelled.append(True)
                with self.assertRaises(asyncio.TimeoutError):
                    await broker.activate(prepare, timeout=0.02)
                self.assertEqual(cancelled, [True])
                self.assertIsNone(broker.process)

    async def test_concurrent_activation_rejected(self):
        with ActivationListener(self.directory) as broker:
            async def forbidden():
                self.fail('No client connected')
            pending = asyncio.create_task(broker.activate(forbidden, timeout=2))
            await asyncio.sleep(0)
            with self.assertRaises(RuntimeError):
                await broker.activate(forbidden, timeout=0.01)
            pending.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await pending

    async def test_competing_broker_preserves_original_socket(self):
        with ActivationListener(self.directory) as broker:
            identity = broker.path.stat().st_ino
            with self.assertRaises(BlockingIOError):
                with ActivationListener(self.directory):
                    self.fail('Competing broker acquired the lock')
            self.assertEqual(broker.path.stat().st_ino, identity)

    async def test_foreign_socket_not_deleted(self):
        self.directory.mkdir(mode=0o700)
        path = self.directory / 'monado_comp_ipc'
        with socket.socket(socket.AF_UNIX) as foreign:
            foreign.bind(str(path))
            with self.assertRaises(OSError):
                with ActivationListener(self.directory):
                    self.fail('Existing socket was replaced')
            self.assertTrue(path.exists())

    async def test_unsafe_directory_rejected(self):
        self.directory.mkdir(mode=0o755)
        with self.assertRaises(ValueError):
            with ActivationListener(self.directory):
                self.fail('Public runtime directory was accepted')

    async def test_invalid_inherited_descriptors_fail_closed(self):
        for value in ('', '-1', '0', '1', '2', '999999999999999999', ' 3', '3x'):
            run = subprocess.run([str(self.native)],
                                 env=dict(os.environ, METEOR_XR_LISTEN_FD=value), timeout=2)
            self.assertEqual(run.returncode, 2)
        with socket.socket(socket.AF_INET) as tcp:
            tcp.bind(('127.0.0.1', 0)); tcp.listen()
            run = subprocess.run([str(self.native)], pass_fds=(tcp.fileno(),),
                                 env=dict(os.environ, METEOR_XR_LISTEN_FD=str(tcp.fileno())), timeout=2)
            self.assertEqual(run.returncode, 2)


if __name__ == '__main__':
    unittest.main()
