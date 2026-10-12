#!/usr/bin/env python3
"""Compare shipped TFLite graphs with Meteor ONNX on one identical image.

CPU inference isolates graph parity, NOT Quest GPU delegate precision or
live capture correctness. Inverted-input rows test orientation sensitivity.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort
from ai_edge_litert.interpreter import Interpreter
from PIL import Image, ImageDraw

from run_models import infer_zipdepth, robust_range


def normalized(raw):
    lo, hi = robust_range(raw, 0.02, 512)
    return np.clip((raw - lo) / max(hi - lo, 1e-6), 0, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--host-models", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path(__file__).resolve().parents[2]
    image = Image.open(args.image).convert("RGB")
    specs = [
        ("384", "zipdepth-base-384-standard-packed-conv4-reduceconv-edgepad-gpu.tflite", 384, 384, 0, "zipdepth_edgepad_384.onnx"),
        ("512", "zipdepth-wide-512x288-edgepad-gpu.tflite", 512, 288, 0, "zipdepth_wide_512x288.onnx"),
        ("320", "zipdepth-wide-320x180-t320x192-edgepad-gpu.tflite", 320, 192, 6, None),
    ]
    sheet = Image.new("RGB", (480 * 4, 300 * len(specs)), "#15171b")
    draw = ImageDraw.Draw(sheet)
    report = {"scope": "Desktop CPU graph parity; not headset GPU or live transport", "models": {}}
    for row, (label, filename, w, h, pad, host_name) in enumerate(specs):
        rgb = np.asarray(image.resize((w, h - 2 * pad), Image.Resampling.LANCZOS), dtype=np.float32) / 255
        rgb = np.pad(rgb, ((pad, pad), (0, 0), (0, 0)), mode="edge")
        interp = Interpreter(model_path=str(root / "models" / filename), num_threads=4)
        interp.allocate_tensors()
        raw = infer_zipdepth(interp, rgb, w, h)
        inverted = infer_zipdepth(interp, rgb[::-1].copy(), w, h)[::-1].copy()
        if pad:
            raw, inverted = raw[pad:-pad], inverted[pad:-pad]
        np.save(args.output / f"edgepad-{label}-raw.npy", raw)
        stats = {"shape": list(raw.shape), "range": [float(raw.min()), float(raw.max())]}
        stats["inverted_input_normalized_mae"] = float(np.abs(normalized(raw) - normalized(inverted)).mean())
        tiles = [("Original", image), (f"TFLite EdgePad-{label}", normalized(raw)), ("Inverted input, restored output", normalized(inverted))]
        if host_name:
            session = ort.InferenceSession(str(args.host_models / host_name), providers=["CPUExecutionProvider"])
            host = session.run(None, {session.get_inputs()[0].name: rgb.transpose(2, 0, 1)[None].copy()})[0].reshape(h, w)
            np.save(args.output / f"meteor-{label}-raw.npy", host)
            span = max(float(np.ptp(host)), 1e-6)
            stats["host_raw_mae_fraction_range"] = float(np.abs(raw - host).mean() / span)
            stats["host_raw_max_fraction_range"] = float(np.abs(raw - host).max() / span)
            stats["host_normalized_mae"] = float(np.abs(normalized(raw) - normalized(host)).mean())
            tiles.append(("Meteor ONNX (same input)", normalized(host)))
        else:
            tiles.append(("No matching Meteor model", image))
        report["models"][label] = stats
        for column, (title, tile) in enumerate(tiles):
            if isinstance(tile, np.ndarray):
                tile = Image.fromarray((tile * 255).astype(np.uint8))
            tile = tile.convert("RGB").resize((480, 270), Image.Resampling.BILINEAR)
            tile.save(args.output / f"{label}-{column}.png")
            sheet.paste(tile, (column * 480, row * 300 + 30))
            draw.text((column * 480 + 8, row * 300 + 8), title, fill="white")
    sheet.save(args.output / "pipeline-comparison.png")
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
