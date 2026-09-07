#!/usr/bin/env python3
"""Create and validate an INT8-weight ZipDepth-384 CPU model.

The source SavedModel is the numerically-equivalent portable rewrite of the
standard ZipDepth convex head. The exported model keeps float32 I/O so Android
can use the existing NHWC capture buffers. The default ``--mode dynamic``
quantizes weights to INT8 while retaining float32 activations (W8A32) for
CPU/XNNPACK execution. ``--mode full`` also quantizes activations using a
representative set, but that mode currently fails ZipDepth quality validation.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image, ImageEnhance
import tensorflow as tf


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SAVED_MODEL = ROOT / "tools/ZipDepth/tflite_384x384"
DEFAULT_FLOAT_MODEL = ROOT / "models/zipdepth-base-384-standard-mobile-gpu.tflite"
DEFAULT_OUTPUT = ROOT / "models/zipdepth-base-384-standard-w8a32.tflite"
SIZE = 384


def calibration_images() -> list[Path]:
    patterns = (
        "tools/ZipDepth/assets/examples/*.jpg",
        "tools/ZipDepth/assets/qualitative/*_rgb.jpg",
        "tools/Depth-Anything-V2/assets/examples/demo*.jpg",
        "tools/model_tester/da_v2_native_verification/*_source.png",
        "tools/model_tester/eg_input_1.png",
        "src/assets/nightfall_shot.png",
    )
    paths: list[Path] = []
    for pattern in patterns:
        paths.extend(ROOT.glob(pattern))
    return sorted(set(paths))


def prepare(path: Path, *, flip: bool = False, brightness: float = 1.0) -> np.ndarray:
    with Image.open(path) as opened:
        image = opened.convert("RGB")
        if flip:
            image = image.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
        if brightness != 1.0:
            image = ImageEnhance.Brightness(image).enhance(brightness)
        image = image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
        return np.asarray(image, dtype=np.float32)[None, ...] / 255.0


def representative_dataset(paths: list[Path]):
    # Multiple deterministic exposure/flip variants broaden activation ranges
    # without requiring a large external calibration download. All source
    # categories include natural scenes; eg_input/nightfall_shot add the large
    # flat regions and sharp text/window edges common in actual streamed PCs.
    for path in paths:
        for flip, brightness in ((False, 1.0), (True, 0.75), (False, 1.2)):
            yield [prepare(path, flip=flip, brightness=brightness)]


def make_interpreter(path: Path):
    interpreter = tf.lite.Interpreter(model_path=str(path), num_threads=4)
    interpreter.allocate_tensors()
    return interpreter


def infer(interpreter, image: np.ndarray) -> np.ndarray:
    input_detail = interpreter.get_input_details()[0]
    output_detail = interpreter.get_output_details()[0]
    interpreter.set_tensor(input_detail["index"], image.astype(input_detail["dtype"]))
    interpreter.invoke()
    return interpreter.get_tensor(output_detail["index"]).astype(np.float32).reshape(SIZE, SIZE)


def normalized(depth: np.ndarray) -> np.ndarray:
    lo, hi = np.percentile(depth, (2.0, 98.0))
    return np.clip((depth - lo) / max(float(hi - lo), 1e-6), 0.0, 1.0)


def validate(float_model: Path, int8_model: Path, paths: list[Path]) -> None:
    reference = make_interpreter(float_model)
    candidate = make_interpreter(int8_model)
    details = candidate.get_input_details()[0], candidate.get_output_details()[0]
    print(f"model boundary: input={details[0]['shape']}/{details[0]['dtype']} "
          f"output={details[1]['shape']}/{details[1]['dtype']}")

    correlations: list[float] = []
    normalized_maes: list[float] = []
    for path in paths:
        image = prepare(path)
        expected = infer(reference, image)
        actual = infer(candidate, image)
        correlation = float(np.corrcoef(expected.ravel(), actual.ravel())[0, 1])
        mae = float(np.mean(np.abs(normalized(expected) - normalized(actual))))
        correlations.append(correlation)
        normalized_maes.append(mae)
        print(f"{path.name}: corr={correlation:.6f} normalized_mae={mae:.6f}")

    print(
        f"validation: images={len(paths)} min_corr={min(correlations):.6f} "
        f"mean_corr={np.mean(correlations):.6f} "
        f"max_normalized_mae={max(normalized_maes):.6f} "
        f"mean_normalized_mae={np.mean(normalized_maes):.6f}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--saved-model", type=Path, default=DEFAULT_SAVED_MODEL)
    parser.add_argument("--float-model", type=Path, default=DEFAULT_FLOAT_MODEL)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--mode", choices=("dynamic", "full"), default="dynamic")
    args = parser.parse_args()

    paths = calibration_images()
    if not paths:
        raise SystemExit("No representative calibration images found")
    if args.mode == "full":
        print(f"Calibrating with {len(paths)} images, {len(paths) * 3} samples")
    else:
        print("Building w8a32 model (int8 weights, float32 activations)")

    converter = tf.lite.TFLiteConverter.from_saved_model(str(args.saved_model))
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    if args.mode == "full":
        converter.representative_dataset = lambda: representative_dataset(paths)
        converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
        # Preserve Nightfall's existing float32 NHWC Java boundary. Quantize
        # and dequantize nodes are inserted immediately inside the model.
        converter.inference_input_type = tf.float32
        converter.inference_output_type = tf.float32
    model = converter.convert()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(model)
    print(f"Wrote {args.output} ({len(model) / 1024 / 1024:.1f} MiB)")
    validate(args.float_model, args.output, paths)


if __name__ == "__main__":
    main()
