#!/usr/bin/env python3
"""Reads test/stream_pattern.gd's blocks back out of a recorded stream.

  analyze_stream_pattern.py VIDEO [--frames VIDEO.frames.tsv] --x 0 --y 0 --block 48

VIDEO is an elementary stream (.hevc/.h264), e.g. from Meteor's --dump-video.
--x/--y/--block are the pattern's place and block size in stream pixels. The
optional frames file (written by --dump-video next to the video) gives each
frame's arrival time at Meteor, for latency.

Prints JSON: how many frames carried a readable pattern, frame-counter gaps
(frames the host never sent) and repeats (the same frame sent twice), and
the time from drawing the pattern to the frame reaching Meteor.
"""
import argparse
import json
import shutil
import statistics
import subprocess
import sys
from pathlib import Path

BITS = 24
BLOCKS = BITS + 2
WRAP = 1 << BITS


def read_rows(frame, width, block):
    """Two 24-bit values from one gray frame, or None if the guards don't read."""
    values = []
    for row in range(2):
        cy = row * block + block // 2

        def level(index):
            cx = index * block + block // 2
            samples = [frame[(cy + dy) * width + cx + dx] for dy in (-2, 0, 2) for dx in (-2, 0, 2)]
            return sum(samples) / len(samples)

        white, black = level(0), level(BLOCKS - 1)
        if white - black < 64:
            return None
        threshold = (white + black) / 2
        value = 0
        for bit in range(BITS):
            value = (value << 1) | (1 if level(bit + 1) > threshold else 0)
        values.append(value)
    return values


def decode(video, x, y, block):
    width, height = BLOCKS * block, 2 * block
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise FileNotFoundError('ffmpeg not found (run with the host /usr/bin/python3)')
    command = [ffmpeg, '-v', 'error', '-i', str(video), '-vf', f'crop={width}:{height}:{x}:{y},format=gray',
               '-f', 'rawvideo', '-']
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    size = width * height
    rows = []
    while True:
        frame = process.stdout.read(size)
        if len(frame) < size:
            break
        rows.append(read_rows(frame, width, block))
    process.wait()
    return rows


def arrivals(path):
    """Arrival times in ms, one per frame, from a --dump-video frames file."""
    if not path or not Path(path).exists():
        return None
    times = []
    for line in Path(path).read_text().splitlines():
        if line and not line.startswith('#'):
            times.append(int(line.split('\t')[1]) / 1000.0)
    return times


def analyze(rows, arrived=None):
    readable = [(i, r) for i, r in enumerate(rows) if r is not None]
    result = {'frames': len(rows), 'readable': len(readable)}
    if not readable:
        return result
    counters = [r[0] for _, r in readable]
    gaps = repeats = 0
    for previous, current in zip(counters, counters[1:]):
        step = (current - previous) % WRAP
        if step == 0:
            repeats += 1
        elif step > 1:
            gaps += step - 1
    span = (counters[-1] - counters[0]) % WRAP + 1
    result.update(pattern_frames=span, missing=gaps, repeated=repeats,
                  missing_pct=round(100.0 * gaps / span, 2))
    if arrived and len(arrived) >= len(rows):
        latency = sorted(((int(arrived[i]) - r[1]) % WRAP) for i, r in readable)
        latency = [ms for ms in latency if ms < 10000]  # wrapped or unreadable times
        if latency:
            result.update(latency_ms_median=statistics.median(latency),
                          latency_ms_p95=latency[int(0.95 * (len(latency) - 1))],
                          latency_ms_max=latency[-1])
        seconds = (arrived[readable[-1][0]] - arrived[readable[0][0]]) / 1000.0
        if seconds > 0:
            result['received_fps'] = round((len(readable) - 1) / seconds, 1)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('video', type=Path)
    parser.add_argument('--frames', type=Path, help='default: VIDEO.frames.tsv')
    parser.add_argument('--x', type=int, default=0)
    parser.add_argument('--y', type=int, default=0)
    parser.add_argument('--block', type=int, default=48)
    args = parser.parse_args(argv)
    frames = args.frames or Path(str(args.video) + '.frames.tsv')
    result = analyze(decode(args.video, args.x, args.y, args.block), arrivals(frames))
    print(json.dumps(result, indent=2))
    return 0 if result.get('readable') else 1


if __name__ == '__main__':
    sys.exit(main())
