"""Check decoded diagnostic pixels, allowing H.264 4:2:0 conversion losses."""
import pathlib
import sys


def validate(data: bytes, *, frames: int = 5, green: int = 64, greens=None) -> None:
    width, height = 512, 256
    if len(data) != width * height * 3 * frames:
        raise ValueError("Wrong decoded frame count/size")
    if greens is not None and len(greens) != frames:
        raise ValueError("Wrong frame marker count")
    for frame in range(frames):
        frame_green = greens[frame] if greens is not None else green
        # Sample both sides of each step away from 4:2:0/color boundaries.
        for x in (32, 96, 160, 224, 288, 352, 416, 480):
            for y in (32, 96, 160, 224):
                left = x < 256
                expected = (255 if x < 128 else 128, frame_green, 0) if left else (0, frame_green, 255 if y < 128 else 128)
                offset = ((frame * height + y) * width + x) * 3
                actual = data[offset : offset + 3]
                if not all(abs(a - b) <= 20 for a, b in zip(actual, expected)):
                    raise ValueError(f"Frame {frame}, pixel {x},{y}: {tuple(actual)} != {expected}")


if __name__ == "__main__":
    validate(pathlib.Path(sys.argv[1]).read_bytes())
    print("PASS: five decoded stereo frames retain eye identity, RGB channels and spatial steps")
