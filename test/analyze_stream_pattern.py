#!/usr/bin/env python3
"""Reads test/stream_pattern.gd's blocks back out of a recorded stream.

  analyze_stream_pattern.py VIDEO [--frames VIDEO.frames.tsv] --x 0 --y 0 --block 48

VIDEO is an elementary stream (.hevc/.h264), e.g. from Meteor's --dump-video.
--x/--y/--block are the pattern's place and block size in stream pixels. The
optional frames file (written by --dump-video next to the video) gives each
frame's arrival time at Meteor, for latency.

Prints JSON: how many frames carried a readable pattern, frames lost (gaps
in the drawn times longer than a frame period), repeats (the same drawn
frame sent twice), and the time from drawing the pattern to the frame
reaching Meteor.
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
        fields = line.split('\t')
        # A Meteor stopped mid-write leaves the last line short.
        if line.startswith('#') or len(fields) < 4 or not fields[1].isdigit():
            continue
        times.append(int(fields[1]) / 1000.0)
    return times


def analyze(rows, arrived=None, fps=None):
    """Frames lost come from the drawn times: the pattern draws faster than
    the stream captures, so consecutive captured frames should be one frame
    period apart (1/fps, or the median step), and a longer step means frames
    were lost. A repeated counter is the same drawn frame sent twice."""
    readable = [(i, r) for i, r in enumerate(rows) if r is not None]
    result = {'frames': len(rows), 'readable': len(readable)}
    if len(readable) < 2:
        return result
    pairs = list(zip(readable, readable[1:]))
    repeats = sum(1 for (_, a), (_, b) in pairs if a[0] == b[0])
    steps = [((b[1] - a[1]) % WRAP) for (_, a), (_, b) in pairs if a[0] != b[0]]
    steps = [ms for ms in steps if ms < 10000]
    period = 1000.0 / fps if fps else statistics.median(steps)
    missing = sum(max(0, round(ms / period) - 1) for ms in steps)
    expected = len(steps) + missing
    result.update(period_ms=round(period, 2), missing=missing, repeated=repeats,
                  missing_pct=round(100.0 * missing / max(expected, 1), 2),
                  step_ms_p95=sorted(steps)[int(0.95 * (len(steps) - 1))] if steps else None)
    if arrived:
        timed = [(i, r) for i, r in readable if i < len(arrived)]
        latency = sorted(((int(arrived[i]) - r[1]) % WRAP) for i, r in timed)
        latency = [ms for ms in latency if ms < 10000]  # wrapped or unreadable times
        if latency:
            result.update(latency_ms_median=statistics.median(latency),
                          latency_ms_p95=latency[int(0.95 * (len(latency) - 1))],
                          latency_ms_max=latency[-1])
        if len(timed) > 1:
            seconds = (arrived[timed[-1][0]] - arrived[timed[0][0]]) / 1000.0
            if seconds > 0:
                result['received_fps'] = round((len(timed) - 1) / seconds, 1)
            # What the host really sent: steps between arrivals at Meteor.
            gaps = [arrived[b] - arrived[a] for (a, _), (b, _) in zip(timed, timed[1:])]
            lost = sum(max(0, round(ms / period) - 1) for ms in gaps)
            result.update(arrival_lost=lost, arrival_lost_pct=round(100.0 * lost / (len(gaps) + lost), 2),
                          arrival_step_ms_p95=round(sorted(gaps)[int(0.95 * (len(gaps) - 1))], 1))
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('video', type=Path)
    parser.add_argument('--frames', type=Path, help='default: VIDEO.frames.tsv')
    parser.add_argument('--x', type=int, default=0)
    parser.add_argument('--y', type=int, default=0)
    parser.add_argument('--block', type=int, default=48)
    parser.add_argument('--fps', type=float, help='the stream frame rate (default: the median step)')
    args = parser.parse_args(argv)
    frames = args.frames or Path(str(args.video) + '.frames.tsv')
    result = analyze(decode(args.video, args.x, args.y, args.block), arrivals(frames), args.fps)
    print(json.dumps(result, indent=2))
    return 0 if result.get('readable') else 1


if __name__ == '__main__':
    sys.exit(main())
