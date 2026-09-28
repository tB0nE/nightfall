#!/usr/bin/env python3
"""Build a multi-scene plain-linear versus guided-linear comparison sheet."""

import argparse
import re
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


COLUMNS = (
    ("EdgePad-384 plain linear", "edgepad_384_plain_linear_480"),
    ("EdgePad-384 guided linear", "edgepad_384_guided_linear_480"),
    ("EdgePad-256 plain linear", "edgepad_256_plain_linear_480"),
    ("EdgePad-256 guided linear", "edgepad_256_guided_linear_480"),
)


def font(size: int):
    try:
        return ImageFont.truetype("DejaVuSans-Bold.ttf", size)
    except OSError:
        return ImageFont.load_default()


def write_sheet(rows, output: Path) -> None:
    tile_w, tile_h = 480, 270
    label_w, header_h = 190, 48
    canvas = Image.new(
        "RGB",
        (label_w + tile_w * len(COLUMNS), header_h + tile_h * len(rows)),
        "#15171b",
    )
    draw = ImageDraw.Draw(canvas)
    for column, (label, _) in enumerate(COLUMNS):
        draw.text(
            (label_w + column * tile_w + 12, 12), label,
            fill="#f0f0f0", font=font(17),
        )
    for row_index, (label, images) in enumerate(rows):
        y = header_h + row_index * tile_h
        draw.text((12, y + 12), label, fill="#f0f0f0", font=font(19))
        for column, image in enumerate(images):
            canvas.paste(image, (label_w + column * tile_w, y))
    canvas.save(output, compress_level=1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("rows", nargs="+", help="Rows formatted Label=/run/folder")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    gray_rows = []
    color_rows = []
    for item in args.rows:
        label, folder_text = item.split("=", 1)
        folder = Path(folder_text)
        gray_rows.append((label, [
            Image.open(folder / f"{key}_gray.png").convert("RGB")
            for _, key in COLUMNS
        ]))
        color_rows.append((label, [
            Image.open(folder / f"{key}_color.png").convert("RGB")
            for _, key in COLUMNS
        ]))

    write_sheet(gray_rows, args.output_dir / "guided_linear_comparison_gray.png")
    write_sheet(color_rows, args.output_dir / "guided_linear_comparison_color.png")

    per_scene = args.output_dir / "per_scene"
    per_scene.mkdir(exist_ok=True)
    for index, (label, images) in enumerate(gray_rows):
        slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")
        write_sheet([(label, images)], per_scene / f"{index + 1:02d}-{slug}-gray.png")
        write_sheet(
            [(label, color_rows[index][1])],
            per_scene / f"{index + 1:02d}-{slug}-color.png",
        )


if __name__ == "__main__":
    main()
