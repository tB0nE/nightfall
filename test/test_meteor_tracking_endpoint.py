"""Socket regressions for the real tracking endpoint, with synthetic poses."""
import pathlib
import ctypes
import socket
import struct
import subprocess
import tempfile
import time
import unittest
import os
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]


class TrackingEndpointTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="nightfall-tracking-tests-")
        cls.endpoint = str(pathlib.Path(cls.temp.name) / "endpoint")
        cls.host = str(pathlib.Path(cls.temp.name) / "host")
        cls.bridge = str(pathlib.Path(cls.temp.name) / "bridge.so")
        common = ["c++", "-std=c++17", "-O2", "-Wall", "-Wextra", "-Werror",
                  "-I" + str(ROOT / "extensions/nightfall-xr/include")]
        subprocess.run(common + [str(ROOT / "test/pcvr_meteor_tracking_endpoint_test.cpp"),
                                 str(ROOT / "extensions/nightfall-xr/src/pcvr_meteor_tracking_endpoint.cpp"),
                                 "-pthread", "-o", cls.endpoint], check=True)
        subprocess.run(common + [str(ROOT / "test/meteor_tracking_host_probe.cpp"),
                                 "-o", cls.host], check=True)
        subprocess.run(common + [str(ROOT / "test/meteor_tracking_client_bridge.cpp"),
                                 "-pthread", "-shared", "-fPIC", "-o", cls.bridge], check=True)
        cls.library = ctypes.CDLL(cls.bridge)
        cls.library.meteor_tracking_start_v1.argtypes = [ctypes.c_char_p]
        cls.library.meteor_tracking_start_v1.restype = ctypes.c_void_p
        cls.library.meteor_tracking_pose_v1.argtypes = [ctypes.c_void_p, ctypes.c_int64,
                                                     ctypes.POINTER(ctypes.c_float),
                                                     ctypes.POINTER(ctypes.c_uint64)]
        cls.library.meteor_tracking_stop_v1.argtypes = [ctypes.c_void_p]
        cls.library.meteor_tracking_optics_v1.argtypes = [ctypes.c_void_p,ctypes.POINTER(ctypes.c_float)]

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            self.port = reserve.getsockname()[1]
        self.child = subprocess.Popen([self.endpoint, str(self.port)], stdout=subprocess.PIPE,
                                      text=True)
        self.addCleanup(self.cleanup_child)
        self.assertEqual(self.child.stdout.readline().strip(), "READY synthetic tracking publisher")

    def cleanup_child(self):
        if self.child.poll() is None:
            self.child.terminate()
        self.child.wait(timeout=3)
        self.child.stdout.close()

    def test_clock_and_120_fresh_samples(self):
        result = subprocess.run([self.host, str(self.port)], capture_output=True, text=True,
                                timeout=8)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 120)
        self.assertEqual(self.child.wait(timeout=3), 0)

    def test_reserved_bytes_rejected(self):
        request = bytearray(struct.pack("<4sHHQQQ", b"NFXC", 1, 32, 1, 0, 0))
        request[31] = 1
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as peer:
            peer.sendall(request)
            self.assertEqual(peer.recv(1), b"")
        self.assertEqual(self.child.wait(timeout=3), 1)

    def test_optics_packet_and_clean_close(self):
        with socket.create_connection(("127.0.0.1",self.port),timeout=2) as peer:
            peer.sendall(struct.pack("<4sHHQQQ",b"NFXO",1,32,0,0,0))
            packet=b""
            while len(packet)<112:
                chunk=peer.recv(112-len(packet))
                self.assertTrue(chunk); packet+=chunk
            magic,version,size,epoch=struct.unpack_from("<4sHHQ",packet)
            self.assertEqual((magic,version,size,epoch),(b"NFXO",1,112,42))
            eyes=struct.unpack_from("<22f",packet,16)
            self.assertAlmostEqual(eyes[11]-eyes[0],.064)
            self.assertAlmostEqual(eyes[7],-.8)
            self.assertEqual(packet[104:],bytes(8))
            peer.sendall(struct.pack("<4sHHQQQ",b"NFXQ",1,32,0,0,0))
        self.assertEqual(self.child.wait(timeout=3),0)

    def test_bridge_requests_optics_when_enabled(self):
        with patch.dict(os.environ,{"METEOR_XR_HEADSET_OPTICS":"1"}):
            context=self.library.meteor_tracking_start_v1(str(self.port).encode())
        self.assertTrue(context)
        try:
            eyes=(ctypes.c_float*22)()
            self.assertEqual(self.library.meteor_tracking_optics_v1(context,eyes),1)
            self.assertAlmostEqual(eyes[11]-eyes[0],.064)
            self.assertAlmostEqual(eyes[18],-.7)
        finally:
            self.library.meteor_tracking_stop_v1(context)
        self.assertEqual(self.child.wait(timeout=3),0)

    def test_truncated_request_disconnect_is_bounded(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as peer:
            peer.sendall(b"NFXC")
        self.assertEqual(self.child.wait(timeout=3), 1)

    def test_monado_bridge_pose_and_query_limits(self):
        context = self.library.meteor_tracking_start_v1(str(self.port).encode())
        self.assertTrue(context)
        try:
            pose = (ctypes.c_float * 7)()
            stamp = ctypes.c_uint64()
            self.assertEqual(self.library.meteor_tracking_pose_v1(
                context, time.monotonic_ns(), pose, ctypes.byref(stamp)), 1)
            self.assertAlmostEqual(pose[0], .25)
            self.assertAlmostEqual(pose[6], 1)
            self.assertEqual(self.library.meteor_tracking_pose_v1(
                context, time.monotonic_ns()+1_000_000_000, pose, ctypes.byref(stamp)), 0)
        finally:
            self.library.meteor_tracking_stop_v1(context)
        self.assertEqual(self.child.wait(timeout=3), 0)

    def test_monado_bridge_disconnect_invalidates_pose(self):
        context = self.library.meteor_tracking_start_v1(str(self.port).encode())
        self.assertTrue(context)
        try:
            self.child.terminate()
            self.child.wait(timeout=3)
            pose = (ctypes.c_float * 7)()
            stamp = ctypes.c_uint64()
            deadline = time.monotonic()+3
            while time.monotonic() < deadline:
                if not self.library.meteor_tracking_pose_v1(
                        context, time.monotonic_ns(), pose, ctypes.byref(stamp)):
                    break
                time.sleep(.01)
            else:
                self.fail("Disconnected tracking remained valid")
        finally:
            self.library.meteor_tracking_stop_v1(context)


if __name__ == "__main__":
    unittest.main()
