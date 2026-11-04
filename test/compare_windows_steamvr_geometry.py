#!/usr/bin/env python3
"""Compare raytraced colour landmarks before/after SteamVR mirror composition.

PPM files come from METEOR_OPENVR_PROBE_SNAPSHOT and
METEOR_STEAMVR_GEOMETRY_PROBE. No headset or third-party Python modules needed.
This checks image geometry, not pose/timestamp alignment during motion.
"""
import argparse
import json
from pathlib import Path


def landmarks(path):
    magic, size, maximum, pixels = path.read_bytes().split(b"\n", 3)
    assert magic == b"P6" and maximum == b"255"
    width, height = map(int, size.split())
    return landmark_data(width, height, pixels)


def landmark_data(width, height, pixels):
    assert len(pixels) == width * height * 3
    found = {colour: set() for colour in ("red", "green", "blue")}
    for n in range(width * height):
        red, green, blue = pixels[n * 3:n * 3 + 3]
        colour = None
        if red > 20 and red > green * 2.5 and red > blue * 2.5:
            colour = "red"
        elif green > 20 and green > red * 1.6 and green > blue * 1.6:
            colour = "green"
        elif blue > 20 and blue > red * 3 and green > red * 3:
            colour = "blue"
        if colour:
            found[colour].add(n)
    output = {}
    for colour, mask in found.items():
        points = []
        # Isolate the largest connected sphere; compositor badges can contain
        # a few pixels of the same colour elsewhere in the image.
        while mask:
            pending = [mask.pop()]
            component = []
            while pending:
                pixel = pending.pop()
                component.append((pixel % width, pixel // width))
                adjacent = [pixel - width, pixel + width]
                if pixel % width:
                    adjacent.append(pixel - 1)
                if pixel % width < width - 1:
                    adjacent.append(pixel + 1)
                for neighbour in adjacent:
                    if neighbour in mask:
                        mask.remove(neighbour)
                        pending.append(neighbour)
            if len(component) > len(points):
                points = component
        if len(points) < 100:
            raise ValueError(f"Missing {colour} landmark")
        xs, ys = zip(*points)
        output[colour] = {
            "centre": [sum(xs) / len(xs) / width, sum(ys) / len(ys) / height],
            "extent": [(max(xs) - min(xs) + 1) / width, (max(ys) - min(ys) + 1) / height],
            "bounds": [min(xs) / width, min(ys) / height, (max(xs) + 1) / width, (max(ys) + 1) / height],
        }
    return {"size": [width, height], "landmarks": output}


def compare(source, mirror):
    before, after = landmarks(source), landmarks(mirror)
    delta = {}
    for colour in before["landmarks"]:
        a, b = before["landmarks"][colour], after["landmarks"][colour]
        delta[colour] = {
            "centre_delta": [b["centre"][i] - a["centre"][i] for i in (0, 1)],
            "extent_ratio": [b["extent"][i] / a["extent"][i] for i in (0, 1)],
        }
    geometry_ok = all(
        max(map(abs, difference["centre_delta"])) < 0.001
        and all(abs(ratio - 1) < 0.01 for ratio in difference["extent_ratio"])
        for difference in delta.values()
    )
    return {"static_geometry_ok": geometry_ok, "source": before, "mirror": after, "differences": delta}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("mirror", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = compare(args.source, args.mirror)
    serialized = json.dumps(result, indent=2)
    if args.output:
        args.output.write_text(serialized + "\n")
    print(serialized)
