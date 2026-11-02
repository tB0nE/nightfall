#!/usr/bin/python3
"""Exercise bounded poll/error behavior with host FDs; never invokes a GPU."""
import importlib.util
import os
from pathlib import Path
import time
import unittest
spec=importlib.util.spec_from_file_location('capture',Path(__file__).with_name('gpu-x11-capture.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
class FenceWait(unittest.TestCase):
    def test_signaled_does_not_consume_or_close_fd(self):
        read,write=os.pipe()
        try:
            os.write(write,b'x');module.wait_cpu_fence(read,20)
            self.assertEqual(os.read(read,1),b'x')
        finally:os.close(read);os.close(write)
    def test_unsignaled_times_out(self):
        read,write=os.pipe()
        try:
            start=time.monotonic()
            with self.assertRaises(TimeoutError):module.wait_cpu_fence(read,20)
            self.assertLess(time.monotonic()-start,.5)
        finally:os.close(read);os.close(write)
    def test_closed_fd_is_rejected(self):
        read,write=os.pipe();os.close(read)
        try:
            with self.assertRaises(RuntimeError):module.wait_cpu_fence(read,20)
        finally:os.close(write)
    def test_hangup_is_rejected(self):
        read,write=os.pipe();os.close(write)
        try:
            with self.assertRaises(RuntimeError):module.wait_cpu_fence(read,20)
        finally:os.close(read)
if __name__=='__main__':unittest.main()
