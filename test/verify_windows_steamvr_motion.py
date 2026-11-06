#!/usr/bin/env python3
"""Validate decoded GPU scene landmarks against the accompanying wire poses.

Decode every Nth H.264 frame into PPM with ffmpeg, preserving frame order.
The three fixed world-space spheres are defined in windows_openvr_scene.h.
Loading frames without those landmarks are excluded, not counted as matches.
"""
import argparse
import json
import math
from pathlib import Path
from compare_windows_steamvr_geometry import landmark_data


def rotate(q, v):
    x, y, z, w = q
    t = [2 * (y * v[2] - z * v[1]), 2 * (z * v[0] - x * v[2]), 2 * (x * v[1] - y * v[0])]
    return [v[0] + w * t[0] + y * t[2] - z * t[1],
            v[1] + w * t[1] + z * t[0] - x * t[2],
            v[2] + w * t[2] + x * t[1] - y * t[0]]


def expected(view, centre):
    local = rotate([-v for v in view[3:6]] + [view[6]], [centre[i] - view[i] for i in range(3)])
    depth = -local[2]
    if depth <= .32:
        return None
    # Centre of the projected sphere silhouette, including its finite radius.
    x, y = [local[i] * depth / (depth * depth - .32 ** 2) for i in (0, 1)]
    left, right, up, down = map(math.tan, view[7:11])
    return [(x - left) / (right - left), (up - y) / (up - down)]


def verify(directory, metadata, step, offset, skip_startup=144):
    records = [json.loads(line) for line in metadata.read_text().splitlines()]
    spheres = {"red": [-.65, 1, -2.4], "green": [0, 1.6, -3.2], "blue": [.65, 1, -2.4]}
    samples, poses, frames = [], [], set()
    for image_index, path in enumerate(sorted(directory.glob("frame-*.ppm"))):
        # SteamVR fades its loading grid over the first scene frames. Colour
        # segmentation cannot locate a sphere obscured by that transition.
        if image_index * step < skip_startup:
            continue
        index = image_index * step + offset
        if index >= len(records):
            break
        magic, size, maximum, pixels = path.read_bytes().split(b"\n", 3)
        assert magic == b"P6" and maximum == b"255"
        width, height = map(int, size.split())
        assert width % 2 == 0 and len(pixels) == width * height * 3
        half = width // 2
        for eye in (0, 1):
            crop = b"".join(pixels[(y * width + eye * half) * 3:(y * width + (eye + 1) * half) * 3] for y in range(height))
            try:
                measured = landmark_data(half, height, crop)["landmarks"]
            except ValueError:
                continue
            view = records[index]["views"][eye * 11:(eye + 1) * 11]
            for colour, centre in spheres.items():
                target = expected(view, centre)
                if target is None:
                    continue
                landmark = measured[colour]
                if any(landmark["bounds"][i] < .01 or landmark["bounds"][i + 2] > .99 for i in (0, 1)):
                    continue
                if any(target[i] - landmark["extent"][i] / 2 < .02 or target[i] + landmark["extent"][i] / 2 > .98 for i in (0, 1)):
                    continue
                error = max(abs(target[i] - landmark["centre"][i]) for i in (0, 1))
                samples.append({"image": path.name, "source_frame": index, "eye": eye, "landmark": colour, "error_uv": error})
                frames.add(image_index)
                poses.append(view[3:7])
    errors = sorted(sample["error_uv"] for sample in samples)
    motion = max((2 * math.acos(min(1, abs(sum(a * b for a, b in zip(poses[0], q))))) for q in poses), default=0) if poses else 0
    return {
        "ok": len(samples) >= 12 and len(frames) >= 3 and motion > .02 and max(errors, default=1) < .005,
        "verified_landmarks": len(samples), "scene_frames": len(frames),
        "max_error_uv": max(errors, default=None), "rotation_span_radians": motion,
        "metadata_offset": offset, "samples": samples,
        "startup_frames_excluded": skip_startup,
        "notes": ["Validates image/pose association and static world geometry; not headset comfort or latency.",
                  "Excludes the initial two seconds of compositor loading-grid fade.",
                  "Reference silhouette centres allow up to 0.5% UV error for colour segmentation and H.264 filtering."],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", type=Path)
    parser.add_argument("metadata", type=Path)
    parser.add_argument("--step", type=int, default=20)
    parser.add_argument("--metadata-offset", type=int, default=0)
    parser.add_argument("--skip-startup-frames", type=int, default=144)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.images, args.metadata, args.step, args.metadata_offset, args.skip_startup_frames)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "samples"}, indent=2))
    raise SystemExit(0 if result["ok"] else 1)
