#!/usr/bin/python3
"""Exercise malformed GPU handoffs with local sockets, without any GPU work."""
import array
import importlib.util
import os
from pathlib import Path
import socket
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('capture',Path(__file__).with_name('gpu-x11-capture.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class Handoff(unittest.TestCase):
    def test_missing_fence_rejected(self):
        a,b=socket.socketpair(socket.AF_UNIX,socket.SOCK_SEQPACKET)
        with a,b:
            a.send(b'1234')
            with self.assertRaises(RuntimeError):module.receive_release(b,4)

    def test_valid_fence_waited_and_received_descriptor_closed(self):
        a,b=socket.socketpair(socket.AF_UNIX,socket.SOCK_SEQPACKET)
        read,write=os.pipe()
        try:
            with a,b,patch.object(module,'wait_cpu_fence') as wait:
                a.sendmsg([b'1234'],[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',[read]))])
                self.assertEqual(module.receive_release(b,4),b'1234')
                received=wait.call_args.args[0]
                with self.assertRaises(OSError):os.fstat(received)
                os.fstat(read)  # Sender retains ownership of its own descriptor.
        finally:os.close(read);os.close(write)

    def test_extra_fences_rejected_and_closed(self):
        a,b=socket.socketpair(socket.AF_UNIX,socket.SOCK_SEQPACKET)
        read,write=os.pipe()
        try:
            with a,b,patch.object(module.os,'close',wraps=os.close) as close:
                a.sendmsg([b'1234'],[(socket.SOL_SOCKET,socket.SCM_RIGHTS,array.array('i',[read,write]))])
                with self.assertRaises(RuntimeError):module.receive_release(b,4)
                self.assertEqual(close.call_count,2)
        finally:os.close(read);os.close(write)

    def test_allocation_bounds(self):
        module.validate_linear_buffer(1919,1079,7680,7680*1080)
        for layout in [(1920,1080,7676,8294400),(1920,1080,7680,8294399),(0,1080,7680,8294400),(1920,1080,7681,9000000)]:
            with self.subTest(layout=layout),self.assertRaises(RuntimeError):module.validate_linear_buffer(*layout)

if __name__=='__main__':unittest.main()
