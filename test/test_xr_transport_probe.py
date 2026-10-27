import struct
import unittest
from unittest.mock import patch
import tempfile
from pathlib import Path

from xr_transport_probe import HEADER, LiveTransport, pack_header, read_exact


class TransportTests(unittest.TestCase):
    def metadata(self):
        view = {"position": [0, 0, 0], "orientation": [0, 0, 0, 1], "fov": [-0.8, 0.8, 0.8, -0.8]}
        return {"frame_id": 9, "display_time_ns": 123456789, "width": 512, "height": 256, "views": [view, view]}

    def test_binary_layout(self):
        payload = b"\0\0\0\1\x65\x11"
        header = pack_header(7, 3, self.metadata(), payload)
        self.assertEqual(len(header), 152)
        self.assertEqual(struct.unpack_from("<QQQQIHH", header, 8), (7, 3, 9, 123456789, 6, 512, 256))
        self.assertEqual(header[48:51], bytes([1, 1, 0]))
        self.assertEqual(header[51:64], bytes(13))
        self.assertEqual(struct.unpack_from("<f", header, 88), (1.,))

    def test_end_layout(self):
        header = pack_header(7, 32)
        self.assertEqual(HEADER.size, 152)
        self.assertEqual(header[50], 1)
        self.assertEqual(header[24:48], bytes(24))
        self.assertEqual(header[64:], bytes(88))

    def test_non_idr(self):
        self.assertEqual(pack_header(7, 1, self.metadata(), b"\0\0\1\x61\x11")[49], 0)

    def test_missing_views_and_empty_payload(self):
        meta = self.metadata()
        with self.assertRaises(ValueError):
            pack_header(7, 0, meta, b"")
        meta["views"] = []
        with self.assertRaises(ValueError):
            pack_header(7, 0, meta, b"\0\0\1\x65")

    def test_fragmented_and_truncated_ack(self):
        class Chunks:
            def __init__(self, data): self.data = data
            def recv(self, length):
                size = min(length, 3)
                value, self.data = self.data[:size], self.data[size:]
                return value
        self.assertEqual(read_exact(Chunks(b"1234567"), 7), b"1234567")
        with self.assertRaises(EOFError):
            read_exact(Chunks(b"123"), 7)

    def test_direct_mode_does_not_start_python_sender(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict("os.environ", {"NIGHTFALL_XR_TRANSPORT_MODE": "direct"}), \
                patch("xr_transport_probe.subprocess.Popen") as process, \
                patch("xr_transport_probe.select.select", return_value=([object()], [], [])), \
                patch("xr_transport_probe.socket.create_connection") as connect, \
                patch("xr_transport_probe.threading.Thread") as thread:
            process.return_value.stdout.readline.return_value = "PORT 1234\n"
            transport = LiveTransport("mock-receiver", Path(directory))
            transport.start()
            self.assertEqual(transport.environment(), {"METEOR_XR_DIRECT_PORT": "1234"})
            connect.assert_not_called()
            thread.assert_not_called()


if __name__ == "__main__":
    unittest.main()
