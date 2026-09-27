#!/usr/bin/env python3
"""Build a multi-scene gallery from zipdepth-resample-384 run folders."""

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


METHODS = (
    ("Linear", "resample_384_linear"),
    ("Bicubic", "resample_384_cubic"),
    ("Tight guided 3x3", "resample_384_guided_3x3"),
    ("Depth-gated 3x3", "resample_384_depth_gated"),
)


def font(size: int):
    try:
        return ImageFont.truetype("DejaVuSans-Bold.ttf", size)
    except OSError:
        return ImageFont.load_default()


def edge_magnitude(gray: Image.Image) -> np.ndarray:
    depth = np.asarray(gray, dtype=np.float32) / 255.0
    gx = np.zeros_like(depth)
    gy = np.zeros_like(depth)
    gx[:, 1:-1] = (depth[:, 2:] - depth[:, :-2]) * 0.5
    gy[1:-1, :] = (depth[2:, :] - depth[:-2, :]) * 0.5
    return np.sqrt(gx * gx + gy * gy)


def write_sheet(rows, output: Path):
    tile_w, tile_h = 480, 270
    label_w, header_h = 180, 42
    columns = ("Source",) + tuple(label for label, _ in METHODS)
    canvas = Image.new(
        "RGB",
        (label_w + tile_w * len(columns), header_h + tile_h * len(rows)),
        "#15171b",
    )
    draw = ImageDraw.Draw(canvas)
    header_font = font(17)
    row_font = font(19)
    for column, label in enumerate(columns):
        draw.text(
            (label_w + column * tile_w + 10, 10), label,
            fill="#f0f0f0", font=header_font,
        )
    for row_index, (row_label, images) in enumerate(rows):
        y = header_h + row_index * tile_h
        draw.text((12, y + 12), row_label, fill="#f0f0f0", font=row_font)
        for column, image in enumerate(images):
            canvas.paste(
                image.convert("RGB").resize(
                    (tile_w, tile_h), Image.Resampling.NEAREST
                ),
                (label_w + column * tile_w, y),
            )
    canvas.save(output, compress_level=1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output_dir", type=Path)
    parser.add_argument(
        "rows", nargs="+", help="Rows formatted as Label=/path/to/run-folder"
    )
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    colour_rows = []
    gray_rows = []
    edge_arrays = []
    for item in args.rows:
        label, folder_text = item.split("=", 1)
        folder = Path(folder_text)
        summary = json.loads((folder / "summary.json").read_text())
        source = Image.open(summary["input"]).convert("RGB").resize(
            (480, 270), Image.Resampling.LANCZOS
        )
        colours = [source]
        grays = [source.convert("L")]
        row_edges = [edge_magnitude(source.convert("L"))]
        for _, key in METHODS:
            colour = Image.open(folder / f"{key}_color.png").convert("RGB")
            gray = Image.open(folder / f"{key}_gray.png").convert("L")
            colours.append(colour)
            grays.append(gray)
            row_edges.append(edge_magnitude(gray))
        colour_rows.append((label, colours))
        gray_rows.append((label, grays))
        edge_arrays.append((label, row_edges))

    all_edges = np.concatenate([
        edge.reshape(-1) for _, row in edge_arrays for edge in row[1:]
    ])
    edge_scale = max(float(np.percentile(all_edges, 99.5)), 1e-6)
    edge_rows = [
        (label, [
            Image.fromarray(
                (np.clip(edge / edge_scale, 0.0, 1.0) * 255.0).astype(np.uint8),
                mode="L",
            )
            for edge in row
        ])
        for label, row in edge_arrays
    ]

    write_sheet(colour_rows, args.output_dir / "comparison_gallery_color.png")
    write_sheet(gray_rows, args.output_dir / "comparison_gallery_gray.png")
    write_sheet(edge_rows, args.output_dir / "comparison_gallery_edges.png")


if __name__ == "__main__":
    main()
