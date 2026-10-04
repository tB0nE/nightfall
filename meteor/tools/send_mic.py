#!/usr/bin/env python3
"""Sends microphone audio to Meteor the way the headset will, for testing.

Streams a WAV file (48 kHz mono 16-bit) or a test tone to Meteor's
microphone port in real time, one packet per 10 ms (packet format in
meteor/src/mic.rs). Optional packet loss and jitter exercise the jitter
buffer. Standard library only.

    python3 meteor/tools/send_mic.py --tone 440 --seconds 10
    python3 meteor/tools/send_mic.py --wav speech.wav --loss 0.02 --jitter-ms 30
    # then record it: parecord -d nightfall_mic out.wav

Meteor accepts packets from loopback, or from a client streaming through it.
"""

import argparse
import math
import random
import socket
import struct
import time
import wave

MAGIC = b"NFMC"
VERSION = 1
FRAME_SAMPLES = 480  # 10 ms at 48 kHz


def frames_from_wav(path):
    with wave.open(path, "rb") as w:
        if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (48000, 1, 2):
            raise SystemExit(f"{path}: needs 48 kHz mono 16-bit "
                             "(ffmpeg -i in.wav -ar 48000 -ac 1 -sample_fmt s16 out.wav)")
        while True:
            pcm = w.readframes(FRAME_SAMPLES)
            if len(pcm) < FRAME_SAMPLES * 2:
                return
            yield pcm


def frames_from_tone(hz, seconds):
    for i in range(int(seconds * 100)):
        yield b"".join(
            struct.pack("<h", int(12000 * math.sin(2 * math.pi * hz * (i * FRAME_SAMPLES + n) / 48000)))
            for n in range(FRAME_SAMPLES)
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=47902)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--wav")
    source.add_argument("--tone", type=float, metavar="HZ")
    parser.add_argument("--seconds", type=float, default=10, help="length of --tone")
    parser.add_argument("--loss", type=float, default=0, help="fraction of packets to drop")
    parser.add_argument("--jitter-ms", type=float, default=0, help="random extra delay per packet")
    parser.add_argument("--muted", action="store_true", help="set the headset-muted flag")
    args = parser.parse_args()

    frames = frames_from_wav(args.wav) if args.wav else frames_from_tone(args.tone, args.seconds)
    family = socket.AF_INET6 if ":" in args.host else socket.AF_INET
    sock = socket.socket(family, socket.SOCK_DGRAM)
    pending = []  # (send_at, packet) for jitter
    start = time.perf_counter()
    sent = dropped = 0
    for seq, pcm in enumerate(frames):
        header = MAGIC + struct.pack("<BBBBII", VERSION, 1 if args.muted else 0, 0, 0, seq, seq * FRAME_SAMPLES)
        due = start + seq * 0.01
        if random.random() >= args.loss:
            pending.append((due + random.uniform(0, args.jitter_ms) / 1000, header + pcm))
        else:
            dropped += 1
        pending.sort()
        while pending and pending[0][0] <= due:
            sock.sendto(pending.pop(0)[1], (args.host, args.port))
            sent += 1
        wait = due + 0.01 - time.perf_counter()
        if wait > 0:
            time.sleep(wait)
    for _, packet in sorted(pending):
        sock.sendto(packet, (args.host, args.port))
        sent += 1
    print(f"sent {sent} packets, dropped {dropped}, {time.perf_counter() - start:.1f} s")


if __name__ == "__main__":
    main()
