#!/usr/bin/python3
"""Count raw RFB updates without saving or displaying any framebuffer pixels."""
import argparse
import json
import socket
import struct
import time


def measure(host, port, seconds):
    with socket.create_connection((host, port), timeout=5) as connection:
        connection.settimeout(5)

        def read(size):
            chunks = []
            while size:
                part = connection.recv(min(size, 65536))
                if not part:
                    raise ConnectionError('RFB disconnected')
                chunks.append(part)
                size -= len(part)
            return b''.join(chunks)

        version = read(12)
        if version != b'RFB 003.008\n':
            raise ValueError('Expected RFB 3.8')
        connection.sendall(version)
        if 1 not in read(read(1)[0]):
            raise ValueError('Lab no-auth security unavailable')
        connection.sendall(b'\1')
        if read(4) != b'\0' * 4:
            raise ValueError('RFB security failed')
        connection.sendall(b'\1')  # Shared session; do not evict Nightfall.
        header = read(24)
        width, height = struct.unpack('>HH', header[:4])
        read(struct.unpack('>I', header[20:])[0])
        connection.sendall(struct.pack('>BBHBBBBHHHBBBxxx', 0, 0, 0,
                                      32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
        connection.sendall(struct.pack('>BBHi', 2, 0, 1, 0))  # Raw only.
        started = time.monotonic()
        updates = rectangles = pixel_bytes = 0
        timed_out = False
        while time.monotonic() - started < seconds:
            connection.sendall(struct.pack('>BBHHHH', 3, updates > 0, 0, 0, width, height))
            connection.settimeout(max(.1, min(5, seconds - (time.monotonic() - started))))
            try:
                kind = read(1)[0]
                if kind != 0:
                    raise ValueError(f'Unexpected RFB message {kind}')
                count = struct.unpack('>xH', read(3))[0]
                for _ in range(count):
                    x, y, w, h, encoding = struct.unpack('>HHHHi', read(12))
                    if encoding != 0 or x + w > width or y + h > height:
                        raise ValueError('Invalid raw rectangle')
                    size = w * h * 4
                    # Discard pixels as they arrive; never write media to disk.
                    while size:
                        chunk = min(size, 65536)
                        read(chunk)
                        size -= chunk
                        pixel_bytes += chunk
                    rectangles += 1
                if count:
                    updates += 1
            except socket.timeout:
                timed_out = True
                break
        elapsed = time.monotonic() - started
        return dict(duration_s=elapsed, updates=updates, updates_per_s=updates / elapsed,
                    pixel_mib_per_s=pixel_bytes / elapsed / 1024**2,
                    rectangles=rectangles, width=width, height=height,
                    timed_out=timed_out,
                    limits='Raw shared-client delivery including transport; not unique video frames. Adds capture/transfer load.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=5902)
    parser.add_argument('--seconds', type=float, default=10)
    args = parser.parse_args()
    if not 0 < args.seconds <= 60:
        parser.error('Use a bounded duration between 0 and 60 seconds')
    print(json.dumps(measure(args.host, args.port, args.seconds), indent=2))
