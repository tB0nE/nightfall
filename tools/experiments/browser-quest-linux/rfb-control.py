#!/usr/bin/python3
"""Input-only lab RFB control, with paced keys; never requests framebuffer pixels."""
import argparse
import socket
import struct
import time
import urllib.parse

KEYS = {'ctrl': 0xffe3, 'shift': 0xffe1, 'alt': 0xffe9,
        'enter': 0xff0d, 'esc': 0xff1b, 'space': 32, 'tab': 0xff09,
        'left': 0xff51, 'right': 0xff53}
KEYS.update({f'f{i}': 0xffbe + i - 1 for i in range(1, 13)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=5902)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--url')
    actions.add_argument('--text')
    actions.add_argument('--chord')
    actions.add_argument('--click', nargs=2, type=int, metavar=('X', 'Y'))
    args = parser.parse_args()
    if args.url:
        parsed = urllib.parse.urlsplit(args.url)
        if parsed.scheme not in ('http', 'https') or not parsed.hostname:
            parser.error('Navigation accepts only HTTP(S) addresses')

    with socket.create_connection(('127.0.0.1', args.port), 5) as connection:
        connection.settimeout(5)

        def read(size):
            data = b''
            while len(data) < size:
                part = connection.recv(size - len(data))
                if not part:
                    raise ConnectionError('RFB disconnected')
                data += part
            return data

        if read(12) != b'RFB 003.008\n':
            raise RuntimeError('Expected lab RFB 3.8')
        connection.sendall(b'RFB 003.008\n')
        if 1 not in read(read(1)[0]):
            raise RuntimeError('Expected lab no-auth mode')
        connection.sendall(b'\1')
        if read(4) != b'\0' * 4:
            raise RuntimeError('RFB rejected connection')
        connection.sendall(b'\1')  # Shared; preserve other clients.
        header = read(24)
        width, height = struct.unpack('>HH', header[:4])
        read(struct.unpack('>I', header[20:])[0])

        def key(code, down):
            connection.sendall(struct.pack('>BBHI', 4, down, 0, code))

        def chord(text):
            names = text.lower().split('+')
            codes = [KEYS[n] if n in KEYS else ord(n.upper() if 'shift' in names else n)
                     for n in names]
            for code in codes:
                key(code, True)
                time.sleep(.06)
            for code in reversed(codes):
                key(code, False)
                time.sleep(.06)
            time.sleep(.35)

        def type_text(text):
            for char in text:
                code = ord(char)
                if code > 255:
                    code |= 0x01000000  # RFB Unicode keysym.
                key(code, True)
                key(code, False)
                time.sleep(.025)
            time.sleep(.15)

        if args.url:
            # Ctrl+L clears DevTools rather than focusing the address bar there.
            chord('alt+d')
            type_text(args.url)
            chord('enter')
        elif args.text is not None:
            type_text(args.text)
        elif args.chord:
            chord(args.chord)
        else:
            x, y = args.click
            if not (0 <= x < width and 0 <= y < height):
                parser.error('Click is outside the lab display')
            connection.sendall(struct.pack('>BBHH', 5, 0, x, y))
            time.sleep(.1)
            connection.sendall(struct.pack('>BBHH', 5, 1, x, y))
            time.sleep(.1)
            connection.sendall(struct.pack('>BBHH', 5, 0, x, y))
        time.sleep(.3)
    print('Input sent; no framebuffer requested.')


if __name__ == '__main__':
    main()
