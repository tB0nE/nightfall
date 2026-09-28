#!/usr/bin/env python3
"""Build a balanced ZipDepth frame corpus from a local media library."""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import random
import subprocess
from collections import defaultdict
from pathlib import Path


VIDEO_SUFFIXES = {".mkv", ".mp4", ".webm", ".avi", ".mov", ".m4v"}


def category_and_title(root: Path, video: Path) -> tuple[str, str]:
    parts = video.relative_to(root).parts
    category = parts[0] if len(parts) > 1 else "Other"
    if len(parts) >= 3 and category.lower() == "series":
        title = parts[1]
    elif len(parts) >= 2:
        title = parts[1] if video.parent != root else video.stem
    else:
        title = video.stem
    return category, title


def probe_duration(video: Path) -> float | None:
    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "error", "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1", str(video),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=30,
        )
        duration = float(result.stdout.strip())
        return duration if duration >= 60.0 else None
    except (subprocess.SubprocessError, ValueError):
        return None


def safe_stem(text: str) -> str:
    digest = hashlib.sha1(text.encode("utf-8")).hexdigest()[:10]
    return digest


def extract_frame(job: dict[str, object]) -> dict[str, object]:
    output = Path(str(job["output"]))
    output.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-ss", f"{float(job['timestamp']):.3f}",
        "-i", str(job["video"]), "-frames:v", "1",
        "-vf", f"scale={int(job['size'])}:{int(job['size'])}",
        "-pix_fmt", "yuvj420p", "-q:v", "2", str(output),
    ]
    try:
        subprocess.run(
            command,
            check=True,
            timeout=90,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return {**job, "status": "ok"}
    except (subprocess.SubprocessError, OSError) as error:
        return {**job, "status": "failed", "error": str(error)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("library", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--titles-per-category", type=int, default=14)
    parser.add_argument("--videos-per-title", type=int, default=2)
    parser.add_argument("--frames-per-video", type=int, default=10)
    parser.add_argument("--validation-fraction", type=float, default=0.15)
    parser.add_argument("--size", type=int, default=384)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20260925)
    args = parser.parse_args()
    if not args.library.is_dir():
        parser.error(f"media library does not exist: {args.library}")
    if not 0.0 < args.validation_fraction < 0.5:
        parser.error("validation-fraction must be between zero and 0.5")

    rng = random.Random(args.seed)
    grouped: dict[str, dict[str, list[Path]]] = defaultdict(lambda: defaultdict(list))
    for video in args.library.rglob("*"):
        if not video.is_file() or video.suffix.lower() not in VIDEO_SUFFIXES:
            continue
        if video.name.startswith("._") or video.stat().st_size < 1_000_000:
            continue
        category, title = category_and_title(args.library, video)
        grouped[category][title].append(video)

    selected: list[tuple[str, str, str, Path]] = []
    split_summary: dict[str, dict[str, list[str]]] = {}
    for category in sorted(grouped):
        titles = sorted(grouped[category])
        rng.shuffle(titles)
        titles = titles[:args.titles_per_category]
        validation_count = max(1, round(len(titles) * args.validation_fraction))
        validation_titles = set(titles[:validation_count])
        split_summary[category] = {
            "train": sorted(set(titles) - validation_titles),
            "validation": sorted(validation_titles),
        }
        for title in titles:
            videos = sorted(grouped[category][title])
            rng.shuffle(videos)
            split = "validation" if title in validation_titles else "train"
            for video in videos[:args.videos_per_title]:
                selected.append((split, category, title, video))

    print(f"Probing {len(selected)} balanced source videos...")
    jobs: list[dict[str, object]] = []
    sources: list[dict[str, object]] = []
    for source_index, (split, category, title, video) in enumerate(selected):
        duration = probe_duration(video)
        if duration is None:
            continue
        # Avoid title cards and end credits. A tiny deterministic jitter keeps
        # repeated episode structures from landing on identical shot timings.
        low, high = duration * 0.08, duration * 0.90
        source_rng = random.Random(args.seed + source_index)
        timestamps = []
        for frame_index in range(args.frames_per_video):
            position = (frame_index + 0.5) / args.frames_per_video
            base = low + (high - low) * position
            cell = (high - low) / args.frames_per_video
            timestamp = min(high, max(low, base + source_rng.uniform(-0.2, 0.2) * cell))
            timestamps.append(timestamp)
            output = (
                args.output / split /
                f"{safe_stem(str(video))}-{frame_index:03d}.jpg"
            )
            jobs.append({
                "video": str(video),
                "output": str(output),
                "timestamp": timestamp,
                "size": args.size,
                "split": split,
                "category": category,
                "title": title,
            })
        sources.append({
            "path": str(video),
            "category": category,
            "title": title,
            "split": split,
            "duration": duration,
            "timestamps": timestamps,
        })

    print(f"Extracting {len(jobs)} frames with {args.workers} workers...")
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        for index, result in enumerate(executor.map(extract_frame, jobs), 1):
            results.append(result)
            if index % 100 == 0 or index == len(jobs):
                print(f"  {index}/{len(jobs)}")

    failures = [result for result in results if result["status"] != "ok"]
    manifest = {
        "library": str(args.library),
        "seed": args.seed,
        "settings": vars(args),
        "title_splits": split_summary,
        "sources": sources,
        "frame_count": len(results) - len(failures),
        "failures": failures,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, default=str) + "\n", encoding="utf-8"
    )
    print(
        f"Prepared {manifest['frame_count']} frames under {args.output} "
        f"({len(failures)} failures)"
    )


if __name__ == "__main__":
    main()
