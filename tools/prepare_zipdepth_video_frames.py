#!/usr/bin/env python3
"""Extract temporally separated training/validation frames from recordings."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


def duration_seconds(source: Path) -> float:
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", str(source),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return float(result.stdout.strip())


def extract_segment(
    source: Path,
    output_pattern: Path,
    start: float,
    duration: float,
    fps: float,
    size: int,
) -> None:
    if duration <= 0:
        return
    output_pattern.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-ss", f"{start:.3f}", "-t", f"{duration:.3f}",
            "-i", str(source), "-vf", f"fps={fps},scale={size}:{size}",
            "-q:v", "2", str(output_pattern),
        ],
        check=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--fps", type=float, default=0.5)
    parser.add_argument("--size", type=int, default=384)
    parser.add_argument("--block-seconds", type=float, default=300.0)
    parser.add_argument("--validation-seconds", type=float, default=30.0)
    args = parser.parse_args()
    if not args.source.is_file():
        parser.error(f"source does not exist: {args.source}")
    if args.fps <= 0 or args.size <= 0:
        parser.error("fps and size must be positive")
    if not 0 < args.validation_seconds < args.block_seconds:
        parser.error("validation-seconds must be between zero and block-seconds")

    total = duration_seconds(args.source)
    source_name = args.source.stem.replace(" ", "_")
    manifest = {
        "source": str(args.source),
        "duration_seconds": total,
        "fps": args.fps,
        "size": args.size,
        "blocks": [],
    }
    block_index = 0
    block_start = 0.0
    while block_start < total:
        block_duration = min(args.block_seconds, total - block_start)
        validation_duration = min(args.validation_seconds, block_duration * 0.2)
        training_duration = block_duration - validation_duration
        train_pattern = args.output / "train" / f"{source_name}-b{block_index:03d}-%06d.jpg"
        val_pattern = args.output / "validation" / f"{source_name}-b{block_index:03d}-%06d.jpg"
        extract_segment(
            args.source, train_pattern, block_start, training_duration,
            args.fps, args.size,
        )
        extract_segment(
            args.source, val_pattern, block_start + training_duration,
            validation_duration, args.fps, args.size,
        )
        manifest["blocks"].append({
            "index": block_index,
            "start": block_start,
            "training_seconds": training_duration,
            "validation_seconds": validation_duration,
        })
        block_index += 1
        block_start += block_duration

    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Prepared frames under {args.output}")


if __name__ == "__main__":
    main()
