"""Check decoded diagnostic pixels, allowing H.264 4:2:0 conversion losses."""
import pathlib
import sys


def validate(data: bytes, *, frames: int = 5, green: int = 64, greens=None, eye_size: int = 256) -> None:
    if eye_size not in (256,512):
        raise ValueError("Unsupported eye-size profile")
    width, height = eye_size*2, eye_size
    if len(data) != width * height * 3 * frames:
        raise ValueError("Wrong decoded frame count/size")
    if greens is not None and len(greens) != frames:
        raise ValueError("Wrong frame marker count")
    for frame in range(frames):
        frame_green = greens[frame] if greens is not None else green
        # Sample both sides of each step away from 4:2:0/color boundaries.
        for sample_x in (32, 96, 160, 224, 288, 352, 416, 480):
            for sample_y in (32, 96, 160, 224):
                x,y=sample_x*eye_size//256,sample_y*eye_size//256
                left = x < eye_size
                expected = (255 if x < eye_size//2 else 128, frame_green, 0) if left else (0, frame_green, 255 if y < eye_size//2 else 128)
                offset = ((frame * height + y) * width + x) * 3
                actual = data[offset : offset + 3]
                if not all(abs(a - b) <= 20 for a, b in zip(actual, expected)):
                    raise ValueError(f"Frame {frame}, pixel {x},{y}: {tuple(actual)} != {expected}")


if __name__ == "__main__":
    validate(pathlib.Path(sys.argv[1]).read_bytes())
    print("PASS: five decoded stereo frames retain eye identity, RGB channels and spatial steps")
