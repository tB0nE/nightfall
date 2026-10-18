"""Loopback receiver harness: native callback delivery by default.

The old Python spool sender remains available only for comparison. This is not
the production authenticated remote transport.
"""
import hashlib
import json
import math
import os
import re
import secrets
import select
import socket
import struct
import subprocess
import threading
from pathlib import Path

from check_nvenc_stereo import validate

HEADER = struct.Struct("<4sHHQQQQIHHBBB13s22f")
MAX_PAYLOAD = 8 * 1024 * 1024


def pack_header(epoch, sequence, metadata=None, payload=b""):
    if metadata is None:
        return HEADER.pack(b"NFXR", 1, 152, epoch, sequence, 0, 0, 0, 0, 0, 1, 0, 1, bytes(13), *([0.] * 22))
    values = [v for view in metadata["views"] for key in ("position", "orientation", "fov") for v in view[key]]
    idr = any(nal and nal[0] & 31 == 5 for nal in re.split(b"\x00\x00(?:\x00)?\x01", payload)[1:])
    if not 0 < len(payload) <= MAX_PAYLOAD or len(values) != 22:
        raise ValueError("Invalid frame size/views")
    return HEADER.pack(b"NFXR", 1, 152, epoch, sequence, metadata["frame_id"], metadata["display_time_ns"],
                       len(payload), metadata["width"], metadata["height"], 1, int(idr), 0, bytes(13), *values)


def read_exact(stream, length):
    parts = bytearray()
    while len(parts) < length:
        part = stream.recv(length - len(parts))
        if not part:
            raise EOFError("Truncated transport acknowledgment")
        parts.extend(part)
    return bytes(parts)


class LiveTransport:
    def __init__(self, receiver, out: Path):
        self.receiver, self.out = receiver, out
        self.stop = threading.Event()
        self.errors = []
        self.process = self.thread = self.stream = None
        self.finished = False
        self.mode = os.environ.get("NIGHTFALL_XR_TRANSPORT_MODE", "direct")
        if self.mode not in ("direct", "spool"):
            raise ValueError("Transport mode must be direct or spool")
        self.port = None

    def __enter__(self):
        return self

    def start(self):
        if not self.receiver:
            return self
        for name in ("received.h264", "received.jsonl", "received.rgb", "transport.log"):
            (self.out / name).unlink(missing_ok=True)
        try:
            self.process = subprocess.Popen([self.receiver, str(self.out)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if not select.select([self.process.stdout], [], [], 5)[0]:
                raise TimeoutError("Receiver startup timed out")
            hello = self.process.stdout.readline().split()
            if len(hello) != 2 or hello[0] != "PORT":
                raise RuntimeError("Invalid receiver startup")
            self.port = int(hello[1])
            if self.mode == "direct":
                return self
            self.stream = socket.create_connection(("127.0.0.1", self.port), timeout=5)
            self.stream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.thread = threading.Thread(target=self._send, daemon=True)
            self.thread.start()
            return self
        except BaseException:
            self.abort()
            raise

    def environment(self):
        return {"METEOR_XR_DIRECT_PORT": str(self.port)} if self.receiver and self.mode == "direct" else {}

    def _send(self):
        epoch, sequence, position = secrets.randbits(64) or 1, 0, 0
        try:
            while True:
                ledger = self.out / "monado-stereo.jsonl"
                line = ""
                if ledger.exists():
                    with ledger.open() as source:
                        source.seek(position)
                        line = source.readline(65537)
                        if len(line) > 65536:
                            raise ValueError("Oversized metadata record")
                        if line.endswith("\n"):
                            position = source.tell()
                        else:
                            if line and self.stop.is_set():
                                raise EOFError("Truncated encoder metadata record")
                            line = ""
                if not line:
                    if self.stop.is_set():
                        break
                    self.stop.wait(0.005)
                    continue
                if sequence >= 240:
                    raise ValueError("Diagnostic frame limit exceeded")
                metadata = json.loads(line)
                length = metadata["bytes"]
                if not 0 < length <= MAX_PAYLOAD:
                    raise ValueError("Payload length outside bounds")
                with (self.out / "monado-stereo.h264").open("rb") as video:
                    video.seek(metadata["offset"])
                    payload = video.read(length)
                if len(payload) != length:
                    raise EOFError("Incomplete encoder spool")
                self.stream.sendall(pack_header(epoch, sequence, metadata, payload))
                self.stream.sendall(payload)
                expected = struct.pack("<4sQQ", b"NFXA", sequence, metadata["frame_id"])
                if read_exact(self.stream, 20) != expected:
                    raise ValueError("Frame acknowledgment mismatch")
                sequence += 1
            self.stream.sendall(pack_header(epoch, sequence))
            if read_exact(self.stream, 12) != struct.pack("<4sQ", b"NFXE", sequence):
                raise ValueError("End acknowledgment mismatch")
        except BaseException as error:
            self.errors.append(error)

    def finish(self):
        if not self.receiver or self.finished:
            return
        if self.mode == "spool":
            self.stop.set()
            self.thread.join(timeout=10)
            if self.thread.is_alive():
                raise TimeoutError("Transport sender failed to drain")
            if self.errors:
                raise RuntimeError("Transport sender failed") from self.errors[0]
            self.stream.close()
        stdout, stderr = self.process.communicate(timeout=5)
        (self.out / "transport.log").write_text(stdout + stderr)
        if self.process.returncode:
            raise RuntimeError("Transport receiver failed")
        self.finished = True
        sent = [json.loads(line) for line in (self.out / "monado-stereo.jsonl").read_text().splitlines()]
        received = [json.loads(line) for line in (self.out / "received.jsonl").read_text().splitlines()]
        if len(sent) != len(received) or not sent:
            raise ValueError("Transport frame count mismatch")
        if self.mode == "direct":
            log = (self.out / "service.log").read_text()
            if log.count("METEOR_DIRECT_OK") != len(sent) or "METEOR_DIRECT_FAILED" in log:
                raise ValueError("Direct packet delivery evidence missing/failed")
        epoch = received[0]["epoch"]
        for sequence, (original, copy) in enumerate(zip(sent, received)):
            if copy["epoch"] != epoch or copy["sequence"] != sequence:
                raise ValueError("Transport epoch/order mismatch")
            for key in ("frame_id", "display_time_ns", "offset", "bytes", "width", "height"):
                if original[key] != copy[key]:
                    raise ValueError(f"Transport changed {key}")
            values = [v for view in original["views"] for key in ("position", "orientation", "fov") for v in view[key]]
            if not all(math.isclose(a, b, abs_tol=1e-6) for a, b in zip(values, copy["view_values"])):
                raise ValueError("Transport changed poses/FOVs")
        def digest(name):
            with (self.out / name).open("rb") as source:
                return hashlib.file_digest(source, "sha256").digest()
        if digest("monado-stereo.h264") != digest("received.h264"):
            raise ValueError("Transport changed encoded bytes")
        subprocess.run(["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i",
                        str(self.out / "received.h264"), "-pix_fmt", "rgb24", "-f", "rawvideo",
                        str(self.out / "received.rgb")], check=True, timeout=20)
        validate((self.out / "received.rgb").read_bytes(), frames=len(sent), greens=[(i * 73) % 256 for i in range(len(sent))])
        print(f"PASS: {self.mode} loopback transfer of {len(sent)} frames; bytes, poses, FOVs, timestamps and decoded markers match")

    def abort(self):
        self.stop.set()
        if self.stream:
            try:
                self.stream.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            self.stream.close()
        if self.thread:
            self.thread.join(timeout=6)
        if self.process:
            if self.process.poll() is None:
                self.process.kill()
            self.process.communicate(timeout=5)

    def __exit__(self, exc_type, exc, traceback):
        try:
            if not exc_type:
                self.finish()
        finally:
            self.abort()
