#!/usr/bin/env python3
"""Build four-column, multi-scene old-Hybrid versus EdgePad galleries."""

import argparse
import re
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont


COLUMNS = (
    ("Old ZipDepth-384", "zipdepth_384_hybrid_guided_480"),
    ("EdgePad-384", "edgepad_384_production_480"),
    ("Old ZipDepth-256", "zipdepth_256_hybrid_guided_480"),
    ("EdgePad-256", "edgepad_256_production_480"),
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


def write_sheet(rows, output: Path) -> None:
    tile_w, tile_h = 480, 270
    label_w, header_h = 190, 48
    canvas = Image.new(
        "RGB",
        (label_w + tile_w * len(COLUMNS), header_h + tile_h * len(rows)),
        "#15171b",
    )
    draw = ImageDraw.Draw(canvas)
    header_font = font(18)
    row_font = font(19)
    for column, (label, _) in enumerate(COLUMNS):
        draw.text(
            (label_w + column * tile_w + 12, 12), label,
            fill="#f0f0f0", font=header_font,
        )
    for row_index, (label, images) in enumerate(rows):
        y = header_h + row_index * tile_h
        draw.text((12, y + 12), label, fill="#f0f0f0", font=row_font)
        for column, image in enumerate(images):
            canvas.paste(
                image.convert("RGB").resize(
                    (tile_w, tile_h), Image.Resampling.NEAREST
                ),
                (label_w + column * tile_w, y),
            )
    canvas.save(output, compress_level=1)


def write_strip(images, output: Path) -> None:
    """Write one scene with four literal 480x270 tiles and a label header."""
    tile_w, tile_h = 480, 270
    header_h = 48
    canvas = Image.new(
        "RGB", (tile_w * len(COLUMNS), header_h + tile_h), "#15171b"
    )
    draw = ImageDraw.Draw(canvas)
    header_font = font(18)
    for column, ((label, _), image) in enumerate(zip(COLUMNS, images)):
        x = column * tile_w
        draw.text((x + 12, 12), label, fill="#f0f0f0", font=header_font)
        canvas.paste(image.convert("RGB"), (x, header_h))
    canvas.save(output, compress_level=1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_dir", type=Path)
    parser.add_argument(
        "rows", nargs="+", help="Rows formatted as Label=/path/to/run-folder"
    )
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    color_rows = []
    gray_rows = []
    edge_arrays = []
    for item in args.rows:
        label, folder_text = item.split("=", 1)
        folder = Path(folder_text)
        colors = []
        grays = []
        edges = []
        for _, key in COLUMNS:
            color = Image.open(folder / f"{key}_color.png").convert("RGB")
            gray = Image.open(folder / f"{key}_gray.png").convert("L")
            colors.append(color)
            grays.append(gray)
            edges.append(edge_magnitude(gray))
        color_rows.append((label, colors))
        gray_rows.append((label, grays))
        edge_arrays.append((label, edges))

    all_edges = np.concatenate([
        edge.reshape(-1) for _, row in edge_arrays for edge in row
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

    write_sheet(color_rows, args.output_dir / "edgepad_comparison_color.png")
    write_sheet(gray_rows, args.output_dir / "edgepad_comparison_gray.png")
    write_sheet(edge_rows, args.output_dir / "edgepad_comparison_edges.png")
    strips_dir = args.output_dir / "per_scene"
    strips_dir.mkdir(exist_ok=True)
    for row_index, (label, colors) in enumerate(color_rows):
        slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")
        write_strip(colors, strips_dir / f"{slug}_color.png")
        write_strip(gray_rows[row_index][1], strips_dir / f"{slug}_gray.png")
        write_strip(edge_rows[row_index][1], strips_dir / f"{slug}_edges.png")


if __name__ == "__main__":
    main()
