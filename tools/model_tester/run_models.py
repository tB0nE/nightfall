#!/usr/bin/env python3
"""
Offline depth-model comparison harness for Nightfall.

Runs the same int8 CPU models deployed to the headset (plus a couple of
reference/diagnostic extras) against a single input image, using a faithful
Python re-implementation of DepthEstimator.java's exact preprocessing,
quantization, and postProcess() normalization - so results here should be
representative of what actually happens on-device (minus temporal smoothing,
which needs a video stream, not a single still image - see NOTES below).

Usage:
    /home/tyrone/.pyenv/versions/3.12.2/bin/python3 run_models.py [input_image]

Focused four-head ZipDepth comparison:
    python3 run_models.py --preset zipdepth-heads [input_image]

This preset writes labeled grayscale, Viridis, and common-scale edge sheets.
Its XNNPACK CPU timings are not representative of Quest GPU performance.

Defaults to eg_input_1.png in this directory. Settings (percentile clips,
dilate/blur radii, which models run) live in settings.json next to this
script - edit that, not this file, for routine experimentation.

NOTES / faithfulness caveats (read before trusting a result too literally):
  - No temporal smoothing: DepthEstimator.java's postProcess() blends new
    estimates into a running EMA across frames (see RANGE_TAU_SECONDS/
    DEPTH_TAU_SECONDS). A single still image only ever sees the "first call"
    path (direct assignment, no blending) - this script replicates exactly
    that, not a converged multi-frame result.
  - Capture downscale: on-device, the source frame is downscaled to each
    model's native resolution via depth_downscale.gdshader's box filter
    (fixed 2026-08-19) before Java ever sees it. This script instead resizes
    the input image directly to each model's target size with PIL's
    high-quality LANCZOS resize, which should be a reasonable stand-in for
    that (now-fixed) shader's own antialiasing - not a bit-exact match.
  - depth_anything_deployed_fp16 is EXPECTED TO FAIL to load (see
    settings.json's note) - that failure is itself the useful result,
    confirming the deployed asset has never been loadable on this CPU path.
"""

import argparse
import json
import struct
import sys
import time
import uuid
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from ai_edge_litert.interpreter import Interpreter

SCRIPT_DIR = Path(__file__).resolve().parent

MODEL_PRESETS = {
    "zipdepth-heads": [
        "zipdepth_384_standard_v1",
        "zipdepth_384_standard_v3",
        "zipdepth_384_hybrid_v1",
        "zipdepth_384_direct_v1",
    ],
    "zipdepth-final-480x270": [
        "zipdepth_384_standard_v1",
        "zipdepth_384_standard_v3",
        "zipdepth_384_hybrid_v1",
        "zipdepth_384_direct_v1",
        "zipdepth_512_direct_v1",
    ],
    "zipdepth-direct-v2": [
        "zipdepth_384_standard_v1",
        "zipdepth_384_direct_v1",
    ],
    "zipdepth-optimized-480x270": [
        "zipdepth_384_standard_v1",
        "zipdepth_384_standard_optimized",
        "zipdepth_384_hybrid_v1",
        "zipdepth_384_direct_v1",
    ],
    "zipdepth-edgepad-widescreen": [
        "zipdepth_384_standard_edgepad",
        "zipdepth_512x288_standard_edgepad",
    ],
    "zipdepth-resample-384": [
        "zipdepth_384_standard_edgepad",
    ],
    "zipdepth-resample-standard-direct": [
        "zipdepth_384_standard_edgepad",
        "zipdepth_384_direct_v1",
    ],
    "zipdepth-256-heads": [
        "zipdepth_384_standard_edgepad",
        "zipdepth_256_standard_edgepad",
        "zipdepth_256_direct_v1",
        "zipdepth_256_hybrid_v1",
    ],
    "zipdepth-edgepad-production": [
        "zipdepth_384_hybrid_v1",
        "zipdepth_384_standard_edgepad",
        "zipdepth_256_hybrid_v1",
        "zipdepth_256_standard_edgepad",
    ],
    "zipdepth-guided-linear": [
        "zipdepth_384_standard_edgepad",
        "zipdepth_256_standard_edgepad",
    ],
    "zipdepth-edgepad-lowres": [
        "zipdepth_256_standard_edgepad",
        "zipdepth_224_standard_edgepad",
        "zipdepth_192_standard_edgepad",
    ],
    "zipdepth-edgepad-384-256-224": [
        "zipdepth_384_standard_edgepad",
        "zipdepth_256_standard_edgepad",
        "zipdepth_224_standard_edgepad",
    ],
}

DISPLAY_NAMES = {
    "zipdepth_384_standard_v1": "Standard v1",
    "zipdepth_384_standard_v2": "Standard v2",
    "zipdepth_384_standard_v3": "Standard v3",
    "zipdepth_384_standard_optimized": "Standard Optimized",
    "zipdepth_384_standard_edgepad": "Standard EdgePad (exact border)",
    "zipdepth_256_standard_edgepad": "Standard EdgePad-256",
    "zipdepth_224_standard_edgepad": "Standard EdgePad-224",
    "zipdepth_192_standard_edgepad": "Standard EdgePad-192",
    "zipdepth_512x288_standard_edgepad": "Standard EdgePad 512x288",
    "edgepad_square_guided_480": "384x384 EdgePad -> guided 480x270",
    "edgepad_wide_guided_480": "512x288 EdgePad -> guided 480x270",
    "edgepad_wide_direct_480": "512x288 EdgePad -> direct sampling",
    "resample_384_linear": "384 EdgePad -> linear 480x270",
    "resample_384_cubic": "384 EdgePad -> cubic 480x270",
    "resample_384_guided_5x5": "384 EdgePad -> current guided 5x5",
    "resample_384_guided_3x3": "384 EdgePad -> tight guided 3x3",
    "resample_384_depth_gated": "384 EdgePad -> depth-gated hi-res guide",
    "resample_384_edge_select": "384 EdgePad -> guided edge select",
    "zipdepth_384_hybrid_v1": "Hybrid v1",
    "zipdepth_384_hybrid_v2": "Hybrid v2",
    "zipdepth_384_direct_v1": "Direct v1 (192 output)",
    "zipdepth_256_direct_v1": "Direct-128",
    "zipdepth_256_hybrid_v1": "ZipDepth-256",
    "zipdepth_512_direct_v1": "Direct-512 (256 output)",
    "standard_v1_final": "Standard v1 (current guided)",
    "direct_v1_bilinear": "Direct v1 (bilinear)",
    "direct_v1_guided": "Direct v1 (current guided)",
    "direct_v2_depth_led": "Direct v2 (3x3 depth-led)",
    "edgepad_256_linear_480": "Standard EdgePad-256 (linear)",
    "edgepad_384_linear_480": "Standard EdgePad-384 (linear)",
    "direct_128_guided_480": "Direct-128 (guided 5x5)",
    "zipdepth_256_guided_480": "ZipDepth-256 (guided 5x5)",
    "zipdepth_384_hybrid_guided_480": "Old ZipDepth-384",
    "edgepad_384_production_480": "EdgePad-384",
    "zipdepth_256_hybrid_guided_480": "Old ZipDepth-256",
    "edgepad_256_production_480": "EdgePad-256",
    "edgepad_384_plain_linear_480": "EdgePad-384 plain linear",
    "edgepad_384_guided_linear_480": "EdgePad-384 guided linear",
    "edgepad_256_plain_linear_480": "EdgePad-256 plain linear",
    "edgepad_256_guided_linear_480": "EdgePad-256 guided linear",
    "edgepad_256_lowres_linear_480": "EdgePad-256",
    "edgepad_224_lowres_linear_480": "EdgePad-224",
    "edgepad_192_lowres_linear_480": "EdgePad-192",
    "edgepad_384_lowres_linear_480": "EdgePad-384",
}

# ---------------------------------------------------------------------------
# Constants mirrored EXACTLY from DepthEstimator.java - keep these in sync by
# hand if the Java side ever changes; there's no automated link between them.
# ---------------------------------------------------------------------------
# No longer hardcoded (2026-08-20) - quantization params are per-export
# (calibration-dependent) and size varies now that a 192px MiDaS variant
# exists alongside the original 256px deployed one. Both are read directly
# from each model's own tensor metadata in infer_midas()/run_one_model(),
# same pattern already used for depth_anything/yolo's per-model sizing.

# Depth Anything's TFLite export reports input shape [1,252,3,252] - not
# clean NHWC [1,252,252,3] or NCHW [1,3,252,252] - a genuine unresolved
# ambiguity flagged earlier in this project's history. DepthEstimator.java
# writes plain sequential per-pixel-interleaved (NHWC) floats into the
# buffer regardless of what the declared shape claims (a raw ByteBuffer
# doesn't care about "shape" at all, just byte order) - this script
# replicates that EXACT behavior (build NHWC data, reinterpret/reshape into
# the model's declared container shape), bug-for-bug, rather than guessing
# at a "corrected" layout. Whatever comes out is what would actually happen
# on-device if this model could load there at all. The originally-deployed
# fp16 asset's native size is 252, NOT the 256 DepthEstimator.java's
# DA_INPUT_SIZE constant assumes - another real, pre-existing mismatch,
# reproduced here rather than silently fixed. As of 2026-08-19 there are
# multiple depth_anything entries at different native sizes (252 reconverted,
# 518 native) - size is read from each model's own declared input tensor
# shape (see infer_depth_anything()/run_one_model()) rather than hardcoded,
# so both work through the same code path without a size-specific branch.


def load_settings():
    with open(SCRIPT_DIR / "settings.json") as f:
        return json.load(f)


def load_source_image(path: Path) -> np.ndarray:
    img = Image.open(path).convert("RGB")
    return img


def resize_rgb(img: Image.Image, width: int, height: int | None = None) -> np.ndarray:
    """High-quality resize to (height, width, 3) float32 RGB in 0..1 - stands in
    for the on-device box-filtered GPU downscale (see module docstring)."""
    if height is None:
        height = width
    resized = img.resize((width, height), Image.LANCZOS)
    return np.asarray(resized, dtype=np.float32) / 255.0


def make_interpreter(model_path: Path):
    interp = Interpreter(model_path=str(model_path), num_threads=4)
    interp.allocate_tensors()
    return interp


# ---------------------------------------------------------------------------
# Per-family inference - each returns a raw (H, W) float32 depth array in
# whatever the model's own native units/convention are (NOT yet normalized -
# that's postProcess()'s job, applied uniformly afterward).
# ---------------------------------------------------------------------------

def infer_midas(interp, rgb01: np.ndarray, size: int) -> np.ndarray:
    # NHWC, quantized uint8 in, quantized uint8 out - see
    # quantizeMidasInput()/dequantizeMidasOutput() in DepthEstimator.java.
    # Scale/zero_point read directly from this model's own tensor metadata
    # rather than hardcoded - a differently-sized/re-calibrated MiDaS export
    # (e.g. a 192px variant) will have genuinely different quantization
    # params than the original 256px deployed model, not just a different
    # input size, and using the wrong ones would silently produce garbage
    # (the exact failure mode this project's MiDaS quantization bug already
    # taught us to watch for once, early on).
    in_detail = interp.get_input_details()[0]
    out_detail = interp.get_output_details()[0]
    in_scale, in_zero_point = in_detail["quantization"]
    out_scale, out_zero_point = out_detail["quantization"]

    q = np.round(rgb01 / in_scale) + in_zero_point
    q = np.clip(q, 0, 255).astype(np.uint8)
    input_data = q.reshape(1, size, size, 3)

    interp.set_tensor(in_detail["index"], input_data)
    interp.invoke()
    out_q = interp.get_tensor(out_detail["index"]).astype(np.float32)
    raw = (out_q - out_zero_point) * out_scale
    return raw.reshape(size, size)


def infer_yolo(interp, rgb01: np.ndarray, size: int) -> np.ndarray:
    # NCHW, float32 I/O (int8 internal, invisible at this boundary) - see
    # runInferenceYolo() in DepthEstimator.java. Output is NEGATED to match
    # MiDaS/DA's inverse-depth convention (larger = nearer) - YOLO26-depth
    # natively outputs regular depth (larger = farther), confirmed via
    # direct visual comparison earlier this project (2026-08-19).
    chw = np.transpose(rgb01, (2, 0, 1))  # (3, size, size)
    input_data = chw.reshape(1, 3, size, size).astype(np.float32)

    in_detail = interp.get_input_details()[0]
    out_detail = interp.get_output_details()[0]
    interp.set_tensor(in_detail["index"], input_data)
    interp.invoke()
    out = interp.get_tensor(out_detail["index"]).astype(np.float32)
    raw = -out.reshape(size, size)
    return raw


def infer_zipdepth(interp, rgb01: np.ndarray, width: int, height: int) -> np.ndarray:
    # NHWC, plain float32 I/O - ImageNet mean/std normalization is baked into
    # the graph itself (see DepthEstimator.java's MODEL_ZIPDEPTH_*_GPU
    # comment), same convention as MiDaS-GPU/depth_anything's GPU exports, so
    # this script sends the same plain 0..1 pixel data every other family
    # gets. Unlike depth_anything, ZipDepth is a plain /32-stride CNN with no
    # ViT patch-size constraint, so its declared input shape is always clean
    # NHWC (1,height,width,3). Output tensor is (1,1,height,width) per onnx2tf's chosen
    # layout for this graph's final op - doesn't matter for a single-channel
    # map, both reshape identically to (size, size) (confirmed during
    # conversion verification, tools/convert_zipdepth.py).
    in_detail = interp.get_input_details()[0]
    out_detail = interp.get_output_details()[0]
    input_data = rgb01.reshape(1, height, width, 3).astype(np.float32)
    interp.set_tensor(in_detail["index"], input_data)
    interp.invoke()
    out = interp.get_tensor(out_detail["index"]).astype(np.float32)
    if out.ndim == 4 and out.shape[0] == 1 and out.shape[-1] == 4:
        # Standard-Optimized leaves the learned 2x reconstruction packed as
        # [top-left, top-right, bottom-left, bottom-right]. Android performs
        # this exact interleave while extracting the depth tensor, including
        # the Standard head's final ReLU clamp.
        packed = out[0]
        packed_height, packed_width, _ = packed.shape
        unpacked = np.empty((packed_height * 2, packed_width * 2), np.float32)
        unpacked[0::2, 0::2] = packed[:, :, 0]
        unpacked[0::2, 1::2] = packed[:, :, 1]
        unpacked[1::2, 0::2] = packed[:, :, 2]
        unpacked[1::2, 1::2] = packed[:, :, 3]
        return np.maximum(unpacked, 0.0)
    # onnx2tf has emitted both NHWC [1,H,W,1] and NCHW [1,1,H,W] across
    # these otherwise equivalent ZipDepth exports. A one-channel map has the
    # same flat order either way, so take the two non-singleton spatial axes.
    spatial_dims = [int(dim) for dim in out_detail["shape"] if int(dim) > 1]
    if len(spatial_dims) != 2:
        raise ValueError(f"unexpected ZipDepth output shape {out_detail['shape']}")
    output_height, output_width = spatial_dims
    return out.reshape(output_height, output_width)


def infer_depth_anything(interp, rgb01: np.ndarray) -> np.ndarray:
    # Builds the same NHWC sequential byte order DepthEstimator.java writes
    # (row-major H,W,C), then reshapes into whatever shape THIS model
    # actually declares - the originally-deployed/reference exports had a
    # genuinely ambiguous/corrupted [1,252,3,252] shape (see settings.json's
    # notes on those entries), while the 2026-08-19 re-conversions (fixed via
    # onnx2tf's -kt input flag, same fix that worked for MiDaS-GPU) produce
    # clean [1,SIZE,SIZE,3] NHWC shapes - reading the declared shape directly
    # rather than hardcoding one lets this function handle any of them
    # (252 reconverted, 518 native, ...) without a model-specific branch.
    # Output H,W is read from the INPUT shape (not output) since a model that
    # declares an ambiguous/wrong-order shape would give a wrong output H,W
    # too - the input shape is what we ourselves control via resize_rgb() in
    # run_one_model(), so it's the trustworthy source for "what H,W did we
    # actually feed in, and what H,W should this square-in/square-out model
    # have produced".
    in_detail = interp.get_input_details()[0]
    out_detail = interp.get_output_details()[0]
    flat = rgb01.reshape(-1)  # row-major H,W,C sequential order
    input_data = flat.reshape(in_detail["shape"]).astype(np.float32)

    interp.set_tensor(in_detail["index"], input_data)
    interp.invoke()
    out = interp.get_tensor(out_detail["index"]).astype(np.float32)
    h, w = int(in_detail["shape"][1]), int(in_detail["shape"][2])
    return out.reshape(h, w)


# ---------------------------------------------------------------------------
# postProcess() replica - robustRange (histogram percentile stretch), plus
# DA-only dilate+box-blur. No temporal smoothing (see module docstring) -
# this is exactly DepthEstimator.java's "!rangeValid"/"smoothedDepthFloat ==
# null" first-call path, direct assignment, no blending.
# ---------------------------------------------------------------------------

def robust_range(raw: np.ndarray, percentile_clip: float, hist_bins: int):
    lo, hi = float(raw.min()), float(raw.max())
    if hi <= lo:
        return lo, lo + 1.0
    hist, edges = np.histogram(raw, bins=hist_bins, range=(lo, hi))
    count = raw.size
    lo_target = int(count * percentile_clip)
    hi_target = int(count * (1.0 - percentile_clip))
    cum = np.cumsum(hist)
    lo_bin = int(np.searchsorted(cum, lo_target))
    hi_bin = int(np.searchsorted(cum, hi_target))
    lo_bin = min(lo_bin, hist_bins - 1)
    hi_bin = min(hi_bin, hist_bins - 1)
    bin_width = (hi - lo) / hist_bins
    robust_lo = lo + lo_bin * bin_width
    robust_hi = lo + (hi_bin + 1) * bin_width
    if robust_hi <= robust_lo:
        robust_hi = robust_lo + 1e-3
    return robust_lo, robust_hi


def dilate_max(depth: np.ndarray, radius: int) -> np.ndarray:
    """Edge-clamped separable max filter - matches DepthEstimator.java's
    dilate() index-clamping exactly (clamps the sample index, doesn't shrink
    the window near edges)."""
    h, w = depth.shape
    horiz = np.zeros_like(depth)
    for dx in range(-radius, radius + 1):
        idx = np.clip(np.arange(w) + dx, 0, w - 1)
        horiz = np.maximum(horiz, depth[:, idx])
    result = np.zeros_like(depth)
    for dy in range(-radius, radius + 1):
        idx = np.clip(np.arange(h) + dy, 0, h - 1)
        result = np.maximum(result, horiz[idx, :])
    return result


def box_blur(depth: np.ndarray, radius: int) -> np.ndarray:
    """Edge-clamped running-sum box blur - matches
    DepthEstimator.java's separableBoxBlur() exactly."""
    diam = radius * 2 + 1
    h, w = depth.shape

    horiz = np.zeros_like(depth)
    idx0 = np.clip(np.arange(-radius, radius + 1), 0, w - 1)
    running = depth[:, idx0].sum(axis=1)
    horiz[:, 0] = running / diam
    for x in range(1, w):
        add_x = min(x + radius, w - 1)
        rem_x = max(x - radius - 1, 0)
        running = running + depth[:, add_x] - depth[:, rem_x]
        horiz[:, x] = running / diam

    result = np.zeros_like(depth)
    idy0 = np.clip(np.arange(-radius, radius + 1), 0, h - 1)
    running = horiz[idy0, :].sum(axis=0)
    result[0, :] = running / diam
    for y in range(1, h):
        add_y = min(y + radius, h - 1)
        rem_y = max(y - radius - 1, 0)
        running = running + horiz[add_y, :] - horiz[rem_y, :]
        result[y, :] = running / diam
    return result


def post_process(raw: np.ndarray, percentile_clip: float, hist_bins: int,
                  dilate_radius: int = 0, blur_radius: int = 0) -> np.ndarray:
    lo, hi = robust_range(raw, percentile_clip, hist_bins)
    scale = 1.0 / max(hi - lo, 1e-6)
    normalized = np.clip((raw - lo) * scale, 0.0, 1.0)
    if dilate_radius > 0:
        normalized = dilate_max(normalized, dilate_radius)
    if blur_radius > 0:
        normalized = box_blur(normalized, blur_radius)
    return np.clip(normalized, 0.0, 1.0)


def to_gray_png(normalized: np.ndarray) -> Image.Image:
    return Image.fromarray((normalized * 255.0).astype(np.uint8), mode="L")


def to_color_png(normalized: np.ndarray) -> Image.Image:
    import matplotlib.cm as cm
    colored = (cm.viridis(normalized)[:, :, :3] * 255.0).astype(np.uint8)
    return Image.fromarray(colored, mode="RGB")


def comparison_sheet(
    source: Image.Image,
    images: list[tuple[str, Image.Image]],
    output: Path,
) -> None:
    """Write a labeled, lossless source + model comparison at native size."""
    tile_width, tile_height = images[0][1].size if images else (384, 384)
    header_height = 42
    columns = [("Source", source.convert("RGB").resize(
        (tile_width, tile_height), Image.Resampling.LANCZOS
    ))] + images
    canvas = Image.new(
        "RGB", (tile_width * len(columns), tile_height + header_height), "#15171b"
    )
    draw = ImageDraw.Draw(canvas)
    try:
        font = ImageFont.truetype("DejaVuSans-Bold.ttf", 22)
    except OSError:
        font = ImageFont.load_default()
    for column, (label, image) in enumerate(columns):
        x = column * tile_width
        canvas.paste(image.convert("RGB").resize(
            (tile_width, tile_height), Image.Resampling.NEAREST
        ), (x, header_height))
        draw.text((x + 12, 9), label, fill="#f0f0f0", font=font)
    canvas.save(output, compress_level=1)


def comparison_two_row_sheet(
    source: Image.Image,
    rows: list[tuple[str, list[tuple[str, Image.Image]]]],
    output: Path,
) -> None:
    """Write a shared-column comparison with one labeled row per model."""
    if not rows or not rows[0][1]:
        return
    tile_width, tile_height = rows[0][1][0][1].size
    header_height = 42
    row_label_width = 190
    column_labels = ["Source"] + [label for label, _ in rows[0][1]]
    canvas = Image.new(
        "RGB",
        (row_label_width + tile_width * len(column_labels),
         header_height + tile_height * len(rows)),
        "#15171b",
    )
    draw = ImageDraw.Draw(canvas)
    try:
        font = ImageFont.truetype("DejaVuSans-Bold.ttf", 18)
        row_font = ImageFont.truetype("DejaVuSans-Bold.ttf", 20)
    except OSError:
        font = ImageFont.load_default()
        row_font = font

    for column, label in enumerate(column_labels):
        draw.text(
            (row_label_width + column * tile_width + 10, 10),
            label,
            fill="#f0f0f0",
            font=font,
        )
    source_tile = source.convert("RGB").resize(
        (tile_width, tile_height), Image.Resampling.LANCZOS
    )
    for row_index, (row_label, images) in enumerate(rows):
        y = header_height + row_index * tile_height
        draw.text((12, y + 12), row_label, fill="#f0f0f0", font=row_font)
        canvas.paste(source_tile, (row_label_width, y))
        for column, (_, image) in enumerate(images, start=1):
            canvas.paste(
                image.convert("RGB").resize(
                    (tile_width, tile_height), Image.Resampling.NEAREST
                ),
                (row_label_width + column * tile_width, y),
            )
    canvas.save(output, compress_level=1)


def edge_magnitude(depth: np.ndarray) -> np.ndarray:
    """Central-difference edge strength used only for visual comparison."""
    gx = np.zeros_like(depth)
    gy = np.zeros_like(depth)
    gx[:, 1:-1] = (depth[:, 2:] - depth[:, :-2]) * 0.5
    gy[1:-1, :] = (depth[2:, :] - depth[:-2, :]) * 0.5
    return np.sqrt(gx * gx + gy * gy)


def nightfall_guided_upsample(
    depth: np.ndarray,
    guide_rgb: np.ndarray,
    source: Image.Image,
    target_width: int = 480,
    target_height: int = 270,
    sigma_r: float = 0.25,
) -> np.ndarray:
    """CPU replica of depth_upsample.gdshader's shipped 5x5 pass.

    DepthEstimator.java sends an 8-bit normalized depth texture to Godot, so
    quantize here before filtering. ``guide_rgb`` is the square model input
    the shader samples with texelFetch; ``source`` supplies the high-resolution
    colour at each 480x270 output pixel.
    """
    low = np.round(np.clip(depth, 0.0, 1.0) * 255.0).astype(np.float32) / 255.0
    guide = np.round(np.clip(guide_rgb, 0.0, 1.0) * 255.0).astype(np.float32) / 255.0
    hi = np.asarray(
        source.convert("RGB").resize(
            (target_width, target_height), Image.Resampling.BILINEAR
        ),
        dtype=np.float32,
    ) / 255.0

    low_h, low_w = low.shape
    guide_h, guide_w = guide.shape[:2]
    uv_x = (np.arange(target_width, dtype=np.float32) + 0.5) / target_width
    uv_y = (np.arange(target_height, dtype=np.float32) + 0.5) / target_height
    lp_x = uv_x[None, :] * low_w - 0.5
    lp_y = uv_y[:, None] * low_h - 0.5
    base_x = np.floor(lp_x).astype(np.int32)
    base_y = np.floor(lp_y).astype(np.int32)

    numerator = np.zeros((target_height, target_width), dtype=np.float32)
    denominator = np.zeros_like(numerator)
    for dy in range(-2, 3):
        qy = np.clip(base_y + dy, 0, low_h - 1)
        guide_y = np.clip(
            ((qy.astype(np.float32) + 0.5) * guide_h / low_h).astype(np.int32),
            0,
            guide_h - 1,
        )
        off_y = qy.astype(np.float32) - lp_y
        for dx in range(-2, 3):
            qx = np.clip(base_x + dx, 0, low_w - 1)
            guide_x = np.clip(
                ((qx.astype(np.float32) + 0.5) * guide_w / low_w).astype(np.int32),
                0,
                guide_w - 1,
            )
            off_x = qx.astype(np.float32) - lp_x
            spatial_weight = np.exp(
                -(off_x * off_x + off_y * off_y) / (2.0 * 1.5 * 1.5)
            )
            sampled_depth = low[qy, qx]
            sampled_guide = guide[guide_y, guide_x]
            colour_delta = hi - sampled_guide
            range_weight = np.exp(
                -np.sum(colour_delta * colour_delta, axis=2)
                / (2.0 * sigma_r * sigma_r)
            )
            weight = spatial_weight * range_weight
            numerator += weight * sampled_depth
            denominator += weight
    return numerator / np.maximum(denominator, 1e-6)


def native_guided_resample(
    depth: np.ndarray,
    guide_rgb: np.ndarray,
    target_width: int = 480,
    target_height: int = 270,
    radius: int = 2,
    sigma_spatial: float = 1.5,
    sigma_r: float = 0.25,
    select_nearest: bool = False,
    source: Image.Image | None = None,
    depth_gate: float = 0.0,
) -> np.ndarray:
    """Replica/variants of the native XR renderer's guided conversion.

    Unlike ``nightfall_guided_upsample`` (the legacy Godot shader replica),
    the native renderer compares both the centre and neighbour colours in the
    model-input guide texture.  This deliberately avoids transferring tiny
    full-resolution text/texture edges that the depth model never observed.
    """
    low = np.round(np.clip(depth, 0.0, 1.0) * 255.0).astype(np.float32) / 255.0
    guide = np.round(np.clip(guide_rgb, 0.0, 1.0) * 255.0).astype(np.float32) / 255.0
    guide_center = np.asarray(
        Image.fromarray((guide * 255.0).astype(np.uint8), mode="RGB").resize(
            (target_width, target_height), Image.Resampling.BILINEAR
        ),
        dtype=np.float32,
    ) / 255.0
    if source is not None:
        # A high-resolution centre guide can place a known depth boundary at
        # sub-model-pixel precision.  It is only allowed to influence regions
        # where the model itself reports a depth discontinuity (depth_gate),
        # preventing desktop text/texture from inventing new depth edges.
        guide_center = np.asarray(
            source.convert("RGB").resize(
                (target_width, target_height), Image.Resampling.BILINEAR
            ),
            dtype=np.float32,
        ) / 255.0
    linear_fallback = np.asarray(
        Image.fromarray(low, mode="F").resize(
            (target_width, target_height), Image.Resampling.BILINEAR
        ),
        dtype=np.float32,
    )

    low_h, low_w = low.shape
    guide_h, guide_w = guide.shape[:2]
    uv_x = (np.arange(target_width, dtype=np.float32) + 0.5) / target_width
    uv_y = (np.arange(target_height, dtype=np.float32) + 0.5) / target_height
    lp_x = uv_x[None, :] * low_w - 0.5
    lp_y = uv_y[:, None] * low_h - 0.5
    base_x = np.floor(lp_x).astype(np.int32)
    base_y = np.floor(lp_y).astype(np.int32)

    numerator = np.zeros((target_height, target_width), dtype=np.float32)
    denominator = np.zeros_like(numerator)
    best_weight = np.full_like(numerator, -1.0)
    selected = np.zeros_like(numerator)
    local_min = np.full_like(numerator, 1.0)
    local_max = np.zeros_like(numerator)
    for dy in range(-radius, radius + 1):
        qy = np.clip(base_y + dy, 0, low_h - 1)
        guide_y = np.clip(
            ((qy.astype(np.float32) + 0.5) * guide_h / low_h).astype(np.int32),
            0,
            guide_h - 1,
        )
        off_y = qy.astype(np.float32) - lp_y
        for dx in range(-radius, radius + 1):
            qx = np.clip(base_x + dx, 0, low_w - 1)
            guide_x = np.clip(
                ((qx.astype(np.float32) + 0.5) * guide_w / low_w).astype(np.int32),
                0,
                guide_w - 1,
            )
            off_x = qx.astype(np.float32) - lp_x
            sampled_depth = low[qy, qx]
            sampled_guide = guide[guide_y, guide_x]
            spatial_weight = np.exp(
                -(off_x * off_x + off_y * off_y)
                / (2.0 * sigma_spatial * sigma_spatial)
            )
            colour_delta = guide_center - sampled_guide
            range_weight = np.exp(
                -np.sum(colour_delta * colour_delta, axis=2)
                / (2.0 * sigma_r * sigma_r)
            )
            weight = spatial_weight * range_weight
            numerator += weight * sampled_depth
            denominator += weight
            local_min = np.minimum(local_min, sampled_depth)
            local_max = np.maximum(local_max, sampled_depth)
            replace = weight > best_weight
            selected = np.where(replace, sampled_depth, selected)
            best_weight = np.where(replace, weight, best_weight)

    if select_nearest:
        return selected
    filtered = numerator / np.maximum(denominator, 1e-6)
    if depth_gate > 0.0:
        edge = np.clip((local_max - local_min - depth_gate) / depth_gate, 0.0, 1.0)
        return linear_fallback * (1.0 - edge) + filtered * edge
    return filtered


def guided_linear_resample(
    depth: np.ndarray,
    guide_rgb: np.ndarray,
    target_width: int = 480,
    target_height: int = 270,
    sigma_r: float = 0.25,
) -> np.ndarray:
    """Replica of the native 2x2 depth-gated guided-linear experiment.

    Hardware-linear depth is retained in flat neighbourhoods. Scale-matched
    colour can only steer the four bilinear weights when those same samples
    already report a depth boundary, preventing colour-only text or texture
    from inventing geometry.
    """
    low = np.round(np.clip(depth, 0.0, 1.0) * 255.0).astype(np.float32) / 255.0
    guide = np.round(np.clip(guide_rgb, 0.0, 1.0) * 255.0).astype(np.float32) / 255.0
    linear = np.asarray(
        Image.fromarray(low, mode="F").resize(
            (target_width, target_height), Image.Resampling.BILINEAR
        ),
        dtype=np.float32,
    )
    guide_center = np.asarray(
        Image.fromarray((guide * 255.0).astype(np.uint8), mode="RGB").resize(
            (target_width, target_height), Image.Resampling.BILINEAR
        ),
        dtype=np.float32,
    ) / 255.0

    low_h, low_w = low.shape
    uv_x = (np.arange(target_width, dtype=np.float32) + 0.5) / target_width
    uv_y = (np.arange(target_height, dtype=np.float32) + 0.5) / target_height
    lp_x = uv_x[None, :] * low_w - 0.5
    lp_y = uv_y[:, None] * low_h - 0.5
    base_x = np.floor(lp_x).astype(np.int32)
    base_y = np.floor(lp_y).astype(np.int32)
    frac_x = lp_x - base_x
    frac_y = lp_y - base_y

    numerator = np.zeros((target_height, target_width), dtype=np.float32)
    denominator = np.zeros_like(numerator)
    local_min = np.full_like(numerator, 1.0)
    local_max = np.zeros_like(numerator)
    for oy in range(2):
        qy = np.clip(base_y + oy, 0, low_h - 1)
        wy = (1.0 - frac_y) if oy == 0 else frac_y
        for ox in range(2):
            qx = np.clip(base_x + ox, 0, low_w - 1)
            wx = (1.0 - frac_x) if ox == 0 else frac_x
            sampled_depth = low[qy, qx]
            sampled_guide = guide[qy, qx]
            colour_delta = guide_center - sampled_guide
            colour_weight = np.exp(
                -np.sum(colour_delta * colour_delta, axis=2)
                / (2.0 * sigma_r * sigma_r)
            )
            weight = wx * wy * colour_weight
            numerator += weight * sampled_depth
            denominator += weight
            local_min = np.minimum(local_min, sampled_depth)
            local_max = np.maximum(local_max, sampled_depth)

    guided = numerator / np.maximum(denominator, 1e-6)
    gate = np.clip(((local_max - local_min) - 0.025) / (0.08 - 0.025), 0.0, 1.0)
    gate = gate * gate * (3.0 - 2.0 * gate)
    return linear * (1.0 - gate * 0.65) + guided * (gate * 0.65)


def depth_led_deblock_upsample(
    depth: np.ndarray,
    target_width: int = 480,
    target_height: int = 270,
    sigma_depth: float = 0.035,
) -> np.ndarray:
    """Cheap Direct-v2 reconstruction: bilinear upscale plus depth-only 3x3.

    Unlike Nightfall's existing 5x5 joint-bilateral pass, this deliberately
    never asks the colour frame where an edge should be.  The bilinear result
    supplies the center/reference depth and nearby low-resolution samples are
    blended only when their depth is already similar.  This should soften
    block boundaries within surfaces without blurring across real depth edges
    or allowing text/texture in the colour frame to invent depth structure.

    The implementation mirrors the intended one-pass GPU shader.  Its nine
    depth taps are substantially cheaper than the current pass's 25 depth,
    25 guide-colour, and one full-resolution colour sample per output pixel.
    """
    low = np.round(np.clip(depth, 0.0, 1.0) * 255.0).astype(np.float32) / 255.0
    center = np.asarray(
        Image.fromarray(low, mode="F").resize(
            (target_width, target_height), Image.Resampling.BILINEAR
        ),
        dtype=np.float32,
    )

    low_h, low_w = low.shape
    uv_x = (np.arange(target_width, dtype=np.float32) + 0.5) / target_width
    uv_y = (np.arange(target_height, dtype=np.float32) + 0.5) / target_height
    lp_x = uv_x[None, :] * low_w - 0.5
    lp_y = uv_y[:, None] * low_h - 0.5
    base_x = np.floor(lp_x + 0.5).astype(np.int32)
    base_y = np.floor(lp_y + 0.5).astype(np.int32)

    numerator = np.zeros((target_height, target_width), dtype=np.float32)
    denominator = np.zeros_like(numerator)
    sigma_spatial = 0.9
    for dy in range(-1, 2):
        qy = np.clip(base_y + dy, 0, low_h - 1)
        off_y = qy.astype(np.float32) - lp_y
        for dx in range(-1, 2):
            qx = np.clip(base_x + dx, 0, low_w - 1)
            off_x = qx.astype(np.float32) - lp_x
            sampled_depth = low[qy, qx]
            spatial_weight = np.exp(
                -(off_x * off_x + off_y * off_y)
                / (2.0 * sigma_spatial * sigma_spatial)
            )
            depth_delta = sampled_depth - center
            range_weight = np.exp(
                -(depth_delta * depth_delta)
                / (2.0 * sigma_depth * sigma_depth)
            )
            weight = spatial_weight * range_weight
            numerator += weight * sampled_depth
            denominator += weight

    filtered = numerator / np.maximum(denominator, 1e-6)
    # Keep the pass deliberately subtle.  Bilinear reconstruction remains the
    # dominant signal; the bilateral estimate only removes low-res stepping.
    return center * 0.35 + filtered * 0.65


# ---------------------------------------------------------------------------
# Model family dispatch
# ---------------------------------------------------------------------------

def family_for(model_key: str) -> str:
    if model_key.startswith("midas"):
        return "midas"
    if model_key.startswith("depth_anything"):
        return "depth_anything"
    if model_key.startswith("yolo26"):
        return "yolo"
    if model_key.startswith("zipdepth"):
        return "zipdepth"
    raise ValueError(f"Can't infer family for model key '{model_key}' - "
                      f"expected it to start with midas/depth_anything/yolo26/zipdepth")


def run_one_model(model_key: str, cfg: dict, settings: dict, source_img: Image.Image):
    family = family_for(model_key)
    model_path = (SCRIPT_DIR / cfg["path"]).resolve()

    result = {"model": model_key, "family": family, "path": str(model_path)}

    t_load_start = time.time()
    try:
        interp = make_interpreter(model_path)
    except Exception as e:
        result["error"] = f"allocate_tensors/load failed: {e}"
        return result
    result["load_time_ms"] = round((time.time() - t_load_start) * 1000, 1)

    if family == "midas":
        # Read this model's own declared size off its input tensor (NHWC,
        # so size is at index 1/2) rather than hardcoding it - see
        # infer_midas() comment.
        size = int(interp.get_input_details()[0]["shape"][1])
        rgb = resize_rgb(source_img, size)
    elif family == "depth_anything":
        # Read this model's own declared native size off its input tensor
        # rather than hardcoding one - see infer_depth_anything() comment.
        da_size = int(interp.get_input_details()[0]["shape"][1])
        rgb = resize_rgb(source_img, da_size)
        size = da_size
    elif family == "yolo":
        # Read this model's own declared size off its input tensor (NCHW,
        # so the size is at index 2/3) rather than parsing it out of the
        # model_key string - multiple quantization schemes at the same
        # resolution (e.g. yolo26n_192 vs yolo26n_192_w8a32) would otherwise
        # break a "last underscore token is the size" parse.
        size = int(interp.get_input_details()[0]["shape"][2])
        rgb = resize_rgb(source_img, size)
    elif family == "zipdepth":
        # NHWC like depth_anything, but rectangular experimental exports are
        # valid. Read H and W independently instead of assuming H == W.
        input_shape = interp.get_input_details()[0]["shape"]
        height = int(input_shape[1])
        width = int(input_shape[2])
        size = width
        rgb = resize_rgb(source_img, width, height)
    else:
        raise AssertionError

    t_infer_start = time.time()
    try:
        if family == "midas":
            raw = infer_midas(interp, rgb, size)
        elif family == "depth_anything":
            raw = infer_depth_anything(interp, rgb)
        elif family == "yolo":
            raw = infer_yolo(interp, rgb, size)
        elif family == "zipdepth":
            raw = infer_zipdepth(interp, rgb, width, height)
    except Exception as e:
        result["error"] = f"invoke failed: {e}"
        return result
    result["infer_time_ms"] = round((time.time() - t_infer_start) * 1000, 1)
    if family == "zipdepth":
        output_height, output_width = raw.shape
        input_label = f"{width}x{height}" if width != height else str(width)
        output_label = (f"{output_width}x{output_height}"
                        if output_width != output_height else str(output_width))
        result["size"] = (input_label if (width, height) == (output_width, output_height)
                          else f"{input_label}->{output_label}")
    else:
        result["size"] = str(size)

    pc = settings["percentile_clip"][family]
    hist_bins = settings["hist_bins"]
    if family == "depth_anything":
        normalized = post_process(
            raw, pc, hist_bins,
            dilate_radius=settings["depth_anything_dilate_radius"],
            blur_radius=settings["depth_anything_blur_radius"],
        )
    elif family == "yolo":
        normalized = post_process(
            raw, pc, hist_bins,
            dilate_radius=settings.get("yolo_dilate_radius", 0),
            blur_radius=settings.get("yolo_blur_radius", 0),
        )
    else:
        normalized = post_process(raw, pc, hist_bins)

    result["raw_min"] = float(raw.min())
    result["raw_max"] = float(raw.max())
    result["raw_mean"] = float(raw.mean())
    result["raw_std"] = float(raw.std())

    result["_normalized"] = normalized  # consumed by caller, not serialized
    result["_guide_rgb"] = rgb
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", nargs="?", type=Path,
                        default=SCRIPT_DIR / "eg_input_1.png")
    parser.add_argument("--preset", choices=sorted(MODEL_PRESETS),
                        help="Run a focused, ordered model comparison")
    parser.add_argument("--models", nargs="+",
                        help="Run only these model keys from settings.json")
    parser.add_argument("--output-dir", type=Path,
                        help="Use this directory instead of a generated run ID")
    args = parser.parse_args()
    input_path = args.input
    if not input_path.exists():
        print(f"Input image not found: {input_path}")
        sys.exit(1)

    settings = load_settings()
    source_img = load_source_image(input_path)

    output_dir = SCRIPT_DIR / "output"
    output_dir.mkdir(exist_ok=True)
    run_id = time.strftime("%H%M%S") + "_" + uuid.uuid4().hex[:4]
    run_dir = args.output_dir or output_dir / f"{run_id}"
    run_dir.mkdir(parents=True, exist_ok=False)

    selected_models = args.models or (MODEL_PRESETS[args.preset] if args.preset else None)
    if selected_models:
        unknown = [key for key in selected_models if key not in settings["models"]]
        if unknown:
            parser.error(f"unknown model key(s): {', '.join(unknown)}")

    lines = []

    def emit(line=""):
        print(line)
        lines.append(line)

    emit(f"Run ID: {run_id}")
    emit(f"Input:  {input_path}")
    emit(f"Output: {run_dir}")
    emit(f"Started: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    emit()

    summary = {"run_id": run_id, "input": str(input_path), "settings": settings, "results": []}

    # load_ms: one-time interpreter/allocate_tensors cost, paid once at
    # startup on-device too (see initialize() in DepthEstimator.java) - NOT
    # a per-frame cost. infer_ms: the actual per-frame generation cost,
    # comparable to on-device logcat's "Inference: Xms" figures. total_ms is
    # load+infer, i.e. the full one-shot cost this script itself paid to
    # produce that model's image (relevant here since every run reloads
    # every interpreter fresh, unlike the always-warm on-device app).
    header = f"{'model':<32} {'size':>9} {'load_ms':>8} {'infer_ms':>9} {'total_ms':>9} {'raw_min':>10} {'raw_max':>10} {'raw_mean':>10} {'raw_std':>10}"
    emit(header)
    emit("-" * len(header))

    run_wall_start = time.time()

    ok_results = []
    failed_results = []

    comparison_gray = []
    comparison_color = []
    normalized_outputs = {}
    guide_outputs = {}
    model_items = settings["models"].items()
    if selected_models:
        model_items = ((key, settings["models"][key]) for key in selected_models)
    for model_key, cfg in model_items:
        if not cfg.get("enabled", True):
            continue
        result = run_one_model(model_key, cfg, settings, source_img)

        if "error" in result:
            failed_results.append(result)
            continue

        normalized = result.pop("_normalized")
        guide_outputs[model_key] = result.pop("_guide_rgb")
        normalized_outputs[model_key] = normalized
        gray_path = run_dir / f"{model_key}_gray.png"
        color_path = run_dir / f"{model_key}_color.png"
        to_gray_png(normalized).save(gray_path)
        to_color_png(normalized).save(color_path)
        label = DISPLAY_NAMES.get(model_key, model_key)
        comparison_gray.append((label, Image.open(gray_path).convert("RGB")))
        comparison_color.append((label, Image.open(color_path).convert("RGB")))

        total_ms = result["load_time_ms"] + result["infer_time_ms"]
        result["total_time_ms"] = round(total_ms, 1)
        ok_results.append(result)

    # Ordered by infer_ms ascending - that's the steady-state per-frame cost
    # we actually care about (load_ms is a one-time startup cost, see the
    # header comment above). Failures sort last since they have no infer_ms.
    ok_results.sort(key=lambda r: r["infer_time_ms"])

    for result in ok_results:
        emit(f"{result['model']:<32} {result['size']:>9} {result['load_time_ms']:>8.1f} "
             f"{result['infer_time_ms']:>9.1f} {result['total_time_ms']:>9.1f} {result['raw_min']:>10.4f} "
             f"{result['raw_max']:>10.4f} {result['raw_mean']:>10.4f} {result['raw_std']:>10.4f}")
        summary["results"].append(result)

    for result in failed_results:
        emit(f"{result['model']:<32} {'':>9} {'':>8} {'':>9} {'':>9}  FAILED: {result['error']}")
        summary["results"].append({k: v for k, v in result.items() if k != "_normalized"})

    run_wall_ms = round((time.time() - run_wall_start) * 1000, 1)
    emit()
    emit(f"Total wall time for this run: {run_wall_ms}ms")
    summary["run_wall_time_ms"] = run_wall_ms

    if args.preset in ("zipdepth-edgepad-lowres", "zipdepth-edgepad-384-256-224") \
            and normalized_outputs:
        # Match Android production: unpack the learned 2x reconstruction in
        # infer_zipdepth(), then hardware-linear scale each native square map
        # into Nightfall's 480x270 working depth texture.
        final_outputs = {}
        postprocess_cpu_ms = {}
        sizes = (384, 256, 224) if args.preset == "zipdepth-edgepad-384-256-224" \
            else (256, 224, 192)
        for size in sizes:
            model_key = f"zipdepth_{size}_standard_edgepad"
            if model_key not in normalized_outputs:
                continue
            start = time.perf_counter()
            output_key = f"edgepad_{size}_lowres_linear_480"
            final_outputs[output_key] = np.clip(np.asarray(
                Image.fromarray(
                    normalized_outputs[model_key].astype(np.float32), mode="F"
                ).resize((480, 270), Image.Resampling.BILINEAR),
                dtype=np.float32,
            ), 0.0, 1.0)
            postprocess_cpu_ms[output_key] = round(
                (time.perf_counter() - start) * 1000.0, 2
            )

        selected_models = list(final_outputs)
        comparison_gray = []
        comparison_color = []
        for key, output in final_outputs.items():
            gray = to_gray_png(output)
            color = to_color_png(output)
            gray.save(run_dir / f"{key}_gray.png")
            color.save(run_dir / f"{key}_color.png")
            comparison_gray.append((DISPLAY_NAMES[key], gray.convert("RGB")))
            comparison_color.append((DISPLAY_NAMES[key], color))
        normalized_outputs = final_outputs
        summary["postprocess_cpu_ms"] = postprocess_cpu_ms
        summary["postprocess_note"] = (
            "All three EdgePad models use the same learned head and plain "
            "linear 480x270 production scaling; only model resolution varies."
        )

    elif args.preset == "zipdepth-direct-v2" and normalized_outputs:
        standard_key = "zipdepth_384_standard_v1"
        direct_key = "zipdepth_384_direct_v1"
        final_outputs = {}
        postprocess_cpu_ms = {}

        if standard_key in normalized_outputs:
            start = time.perf_counter()
            final_outputs["standard_v1_final"] = nightfall_guided_upsample(
                normalized_outputs[standard_key], guide_outputs[standard_key],
                source_img, 480, 270
            )
            postprocess_cpu_ms["standard_v1_current_guided"] = round(
                (time.perf_counter() - start) * 1000.0, 2
            )

        if direct_key in normalized_outputs:
            direct = normalized_outputs[direct_key]
            start = time.perf_counter()
            final_outputs["direct_v1_bilinear"] = np.asarray(
                Image.fromarray(direct.astype(np.float32), mode="F").resize(
                    (480, 270), Image.Resampling.BILINEAR
                ),
                dtype=np.float32,
            )
            postprocess_cpu_ms["direct_v1_bilinear"] = round(
                (time.perf_counter() - start) * 1000.0, 2
            )

            start = time.perf_counter()
            final_outputs["direct_v1_guided"] = nightfall_guided_upsample(
                direct, guide_outputs[direct_key], source_img, 480, 270
            )
            postprocess_cpu_ms["direct_v1_current_guided"] = round(
                (time.perf_counter() - start) * 1000.0, 2
            )

            start = time.perf_counter()
            final_outputs["direct_v2_depth_led"] = depth_led_deblock_upsample(
                direct, 480, 270
            )
            postprocess_cpu_ms["direct_v2_depth_led"] = round(
                (time.perf_counter() - start) * 1000.0, 2
            )

        selected_models = list(final_outputs)
        comparison_gray = []
        comparison_color = []
        for key, output in final_outputs.items():
            gray = to_gray_png(output)
            color = to_color_png(output)
            gray.save(run_dir / f"{key}_480x270_gray.png")
            color.save(run_dir / f"{key}_480x270_color.png")
            comparison_gray.append((DISPLAY_NAMES[key], gray.convert("RGB")))
            comparison_color.append((DISPLAY_NAMES[key], color))
        normalized_outputs = final_outputs
        summary["postprocess_cpu_ms"] = postprocess_cpu_ms
        summary["postprocess_note"] = (
            "Desktop NumPy/Pillow reference timings are not Quest shader "
            "timings; tap counts and texture reads are the useful cost proxy."
        )
        summary["shader_cost_proxy"] = {
            "direct_v1_bilinear": "1 filtered depth lookup",
            "direct_v1_current_guided": (
                "25 depth + 25 low-resolution colour + 1 stream-colour lookup"
            ),
            "direct_v2_depth_led": "9 depth lookups",
        }

    elif args.preset == "zipdepth-guided-linear" and normalized_outputs:
        final_outputs = {}
        postprocess_cpu_ms = {}
        for model_key, prefix in (
            ("zipdepth_384_standard_edgepad", "edgepad_384"),
            ("zipdepth_256_standard_edgepad", "edgepad_256"),
        ):
            if model_key not in normalized_outputs:
                continue
            depth = normalized_outputs[model_key]

            start = time.perf_counter()
            linear = np.asarray(
                Image.fromarray(depth.astype(np.float32), mode="F").resize(
                    (480, 270), Image.Resampling.BILINEAR
                ),
                dtype=np.float32,
            )
            linear_key = f"{prefix}_plain_linear_480"
            final_outputs[linear_key] = np.clip(linear, 0.0, 1.0)
            postprocess_cpu_ms[linear_key] = round(
                (time.perf_counter() - start) * 1000.0, 2
            )

            start = time.perf_counter()
            guided_key = f"{prefix}_guided_linear_480"
            final_outputs[guided_key] = guided_linear_resample(
                depth, guide_outputs[model_key], 480, 270
            )
            postprocess_cpu_ms[guided_key] = round(
                (time.perf_counter() - start) * 1000.0, 2
            )

        selected_models = list(final_outputs)
        comparison_gray = []
        comparison_color = []
        for key, output in final_outputs.items():
            gray = to_gray_png(output)
            color = to_color_png(output)
            gray.save(run_dir / f"{key}_gray.png")
            color.save(run_dir / f"{key}_color.png")
            comparison_gray.append((DISPLAY_NAMES[key], gray.convert("RGB")))
            comparison_color.append((DISPLAY_NAMES[key], color))
        normalized_outputs = final_outputs
        summary["postprocess_cpu_ms"] = postprocess_cpu_ms
        summary["postprocess_note"] = (
            "Local CPU replica of the native renderer comparison. Plain "
            "linear uses bilinear depth sampling; guided linear reweights "
            "the same four taps by scale-matched colour only at depth edges."
        )
        summary["shader_cost_proxy"] = {
            "plain_linear": "1 hardware-filtered depth lookup",
            "guided_linear": (
                "1 filtered depth + 4 depth + 4 guide + 1 filtered-guide lookups"
            ),
        }

    elif args.preset == "zipdepth-edgepad-production" and normalized_outputs:
        final_outputs = {}
        postprocess_cpu_ms = {}
        production_paths = (
            ("zipdepth_384_hybrid_v1", "zipdepth_384_hybrid_guided_480", "guided"),
            ("zipdepth_384_standard_edgepad", "edgepad_384_production_480", "linear"),
            ("zipdepth_256_hybrid_v1", "zipdepth_256_hybrid_guided_480", "guided"),
            ("zipdepth_256_standard_edgepad", "edgepad_256_production_480", "linear"),
        )
        for model_key, output_key, method in production_paths:
            if model_key not in normalized_outputs:
                continue
            start = time.perf_counter()
            if method == "guided":
                output = nightfall_guided_upsample(
                    normalized_outputs[model_key], guide_outputs[model_key],
                    source_img, 480, 270
                )
            else:
                output = np.asarray(
                    Image.fromarray(
                        normalized_outputs[model_key].astype(np.float32), mode="F"
                    ).resize((480, 270), Image.Resampling.BILINEAR),
                    dtype=np.float32,
                )
            final_outputs[output_key] = np.clip(output, 0.0, 1.0)
            postprocess_cpu_ms[output_key] = round(
                (time.perf_counter() - start) * 1000.0, 2
            )

        selected_models = list(final_outputs)
        comparison_gray = []
        comparison_color = []
        for key, output in final_outputs.items():
            gray = to_gray_png(output)
            color = to_color_png(output)
            gray.save(run_dir / f"{key}_gray.png")
            color.save(run_dir / f"{key}_color.png")
            comparison_gray.append((DISPLAY_NAMES[key], gray.convert("RGB")))
            comparison_color.append((DISPLAY_NAMES[key], color))
        normalized_outputs = final_outputs
        summary["postprocess_cpu_ms"] = postprocess_cpu_ms
        summary["postprocess_note"] = (
            "Reproduces each model's final Nightfall depth-map path at "
            "480x270: old Hybrid models use guided 5x5; EdgePad models use "
            "hardware-linear-equivalent bilinear sampling."
        )

    elif args.preset == "zipdepth-256-heads" and normalized_outputs:
        best_key = "zipdepth_384_standard_edgepad"
        edgepad_key = "zipdepth_256_standard_edgepad"
        direct_key = "zipdepth_256_direct_v1"
        hybrid_key = "zipdepth_256_hybrid_v1"
        final_outputs = {}
        postprocess_cpu_ms = {}

        if best_key in normalized_outputs:
            start = time.perf_counter()
            final_outputs["edgepad_384_linear_480"] = np.clip(np.asarray(
                Image.fromarray(
                    normalized_outputs[best_key].astype(np.float32), mode="F"
                ).resize((480, 270), Image.Resampling.BILINEAR),
                dtype=np.float32,
            ), 0.0, 1.0)
            postprocess_cpu_ms["edgepad_384_linear"] = round(
                (time.perf_counter() - start) * 1000.0, 2
            )

        if edgepad_key in normalized_outputs:
            start = time.perf_counter()
            final_outputs["edgepad_256_linear_480"] = np.clip(np.asarray(
                Image.fromarray(
                    normalized_outputs[edgepad_key].astype(np.float32), mode="F"
                ).resize((480, 270), Image.Resampling.BILINEAR),
                dtype=np.float32,
            ), 0.0, 1.0)
            postprocess_cpu_ms["edgepad_256_linear"] = round(
                (time.perf_counter() - start) * 1000.0, 2
            )

        for model_key, output_key in (
            (direct_key, "direct_128_guided_480"),
            (hybrid_key, "zipdepth_256_guided_480"),
        ):
            if model_key not in normalized_outputs:
                continue
            start = time.perf_counter()
            final_outputs[output_key] = nightfall_guided_upsample(
                normalized_outputs[model_key], guide_outputs[model_key],
                source_img, 480, 270
            )
            postprocess_cpu_ms[output_key] = round(
                (time.perf_counter() - start) * 1000.0, 2
            )

        selected_models = list(final_outputs)
        comparison_gray = []
        comparison_color = []
        for key, output in final_outputs.items():
            gray = to_gray_png(output)
            color = to_color_png(output)
            gray.save(run_dir / f"{key}_gray.png")
            color.save(run_dir / f"{key}_color.png")
            comparison_gray.append((DISPLAY_NAMES[key], gray.convert("RGB")))
            comparison_color.append((DISPLAY_NAMES[key], color))
        normalized_outputs = final_outputs
        summary["postprocess_cpu_ms"] = postprocess_cpu_ms
        summary["postprocess_note"] = (
            "Desktop reference timings are not Quest shader timings. EdgePad "
            "uses one linear sample; Direct-128 and ZipDepth-256 use the "
            "production guided 5x5 pass."
        )

    elif args.preset == "zipdepth-edgepad-widescreen" and normalized_outputs:
        square_key = "zipdepth_384_standard_edgepad"
        wide_key = "zipdepth_512x288_standard_edgepad"
        final_outputs = {}
        if square_key in normalized_outputs:
            final_outputs["edgepad_square_guided_480"] = nightfall_guided_upsample(
                normalized_outputs[square_key], guide_outputs[square_key],
                source_img, 480, 270
            )
        if wide_key in normalized_outputs:
            final_outputs["edgepad_wide_guided_480"] = nightfall_guided_upsample(
                normalized_outputs[wide_key], guide_outputs[wide_key],
                source_img, 480, 270
            )
            # The production shader samples normalized UVs from the model
            # texture. Bilinear resize to the comparison canvas reproduces
            # that direct-sampling presentation without a guided pass.
            final_outputs["edgepad_wide_direct_480"] = np.asarray(
                Image.fromarray(
                    normalized_outputs[wide_key].astype(np.float32), mode="F"
                ).resize((480, 270), Image.Resampling.BILINEAR),
                dtype=np.float32,
            )

        selected_models = list(final_outputs)
        comparison_gray = []
        comparison_color = []
        for key, output in final_outputs.items():
            gray = to_gray_png(output)
            color = to_color_png(output)
            gray.save(run_dir / f"{key}_gray.png")
            color.save(run_dir / f"{key}_color.png")
            comparison_gray.append((DISPLAY_NAMES[key], gray.convert("RGB")))
            comparison_color.append((DISPLAY_NAMES[key], color))
        normalized_outputs = final_outputs

    elif args.preset == "zipdepth-resample-standard-direct" and normalized_outputs:
        method_labels = (
            ("Linear", "linear"),
            ("Bicubic", "cubic"),
            ("Current guided 5x5", "guided_5x5"),
            ("Tight guided 3x3", "guided_3x3"),
            ("Depth-gated 3x3", "depth_gated"),
        )
        model_rows = (
            ("Standard 384", "zipdepth_384_standard_edgepad"),
            ("Direct 192", "zipdepth_384_direct_v1"),
        )
        gray_rows = []
        color_rows = []
        edge_rows_raw = []
        for row_label, model_key in model_rows:
            if model_key not in normalized_outputs:
                continue
            depth = normalized_outputs[model_key]
            guide = guide_outputs[model_key]
            variants = {
                "linear": np.clip(np.asarray(
                    Image.fromarray(depth.astype(np.float32), mode="F").resize(
                        (480, 270), Image.Resampling.BILINEAR
                    ), dtype=np.float32), 0.0, 1.0),
                "cubic": np.clip(np.asarray(
                    Image.fromarray(depth.astype(np.float32), mode="F").resize(
                        (480, 270), Image.Resampling.BICUBIC
                    ), dtype=np.float32), 0.0, 1.0),
                "guided_5x5": native_guided_resample(
                    depth, guide, 480, 270, radius=2,
                    sigma_spatial=1.5, sigma_r=0.25
                ),
                "guided_3x3": native_guided_resample(
                    depth, guide, 480, 270, radius=1,
                    sigma_spatial=0.75, sigma_r=0.16
                ),
                "depth_gated": native_guided_resample(
                    depth, guide, 480, 270, radius=1,
                    sigma_spatial=0.75, sigma_r=0.16,
                    source=source_img, depth_gate=0.02
                ),
            }
            gray_rows.append((row_label, [
                (label, to_gray_png(variants[key]))
                for label, key in method_labels
            ]))
            color_rows.append((row_label, [
                (label, to_color_png(variants[key]))
                for label, key in method_labels
            ]))
            edge_rows_raw.append((row_label, [
                (label, edge_magnitude(variants[key]))
                for label, key in method_labels
            ]))

        all_edge_values = np.concatenate([
            edge.reshape(-1)
            for _, images in edge_rows_raw
            for _, edge in images
        ])
        edge_scale = max(float(np.percentile(all_edge_values, 99.5)), 1e-6)
        edge_rows = [
            (row_label, [
                (label, to_gray_png(np.clip(edge / edge_scale, 0.0, 1.0)))
                for label, edge in images
            ])
            for row_label, images in edge_rows_raw
        ]
        comparison_two_row_sheet(
            source_img, gray_rows, run_dir / "comparison_two_rows_gray.png"
        )
        comparison_two_row_sheet(
            source_img, color_rows, run_dir / "comparison_two_rows_color.png"
        )
        comparison_two_row_sheet(
            source_img, edge_rows, run_dir / "comparison_two_rows_edges.png"
        )

    elif args.preset == "zipdepth-resample-384" and normalized_outputs:
        model_key = "zipdepth_384_standard_edgepad"
        final_outputs = {}
        postprocess_cpu_ms = {}
        if model_key in normalized_outputs:
            depth = normalized_outputs[model_key]
            guide = guide_outputs[model_key]

            for output_key, method in (
                ("resample_384_linear", Image.Resampling.BILINEAR),
                ("resample_384_cubic", Image.Resampling.BICUBIC),
            ):
                start = time.perf_counter()
                resized = np.asarray(
                    Image.fromarray(depth.astype(np.float32), mode="F").resize(
                        (480, 270), method
                    ),
                    dtype=np.float32,
                )
                final_outputs[output_key] = np.clip(resized, 0.0, 1.0)
                postprocess_cpu_ms[output_key] = round(
                    (time.perf_counter() - start) * 1000.0, 2
                )

            guided_variants = (
                ("resample_384_guided_5x5", 2, 1.5, 0.25, False, None, 0.0),
                ("resample_384_guided_3x3", 1, 0.75, 0.16, False, None, 0.0),
                ("resample_384_depth_gated", 1, 0.75, 0.16, False, source_img, 0.02),
                ("resample_384_edge_select", 1, 0.75, 0.16, True, None, 0.0),
            )
            for (output_key, radius, sigma_s, sigma_r, select,
                 centre_source, depth_gate) in guided_variants:
                start = time.perf_counter()
                final_outputs[output_key] = native_guided_resample(
                    depth,
                    guide,
                    480,
                    270,
                    radius=radius,
                    sigma_spatial=sigma_s,
                    sigma_r=sigma_r,
                    select_nearest=select,
                    source=centre_source,
                    depth_gate=depth_gate,
                )
                postprocess_cpu_ms[output_key] = round(
                    (time.perf_counter() - start) * 1000.0, 2
                )

        selected_models = list(final_outputs)
        comparison_gray = []
        comparison_color = []
        for key, output in final_outputs.items():
            gray = to_gray_png(output)
            color = to_color_png(output)
            gray.save(run_dir / f"{key}_gray.png")
            color.save(run_dir / f"{key}_color.png")
            comparison_gray.append((DISPLAY_NAMES[key], gray.convert("RGB")))
            comparison_color.append((DISPLAY_NAMES[key], color))
        normalized_outputs = final_outputs
        summary["postprocess_cpu_ms"] = postprocess_cpu_ms
        summary["shader_cost_proxy"] = {
            "linear": "1 filtered depth lookup",
            "cubic": "desktop quality reference; typically 16 taps on GPU",
            "guided_5x5": "25 depth + 26 low-resolution colour lookups",
            "guided_3x3": "9 depth + 10 low-resolution colour lookups",
            "depth_gated": (
                "9 depth + 9 low-resolution colour + 1 stream-colour lookup"
            ),
            "edge_select": "same 3x3 lookups, winner selection instead of averaging",
        }

    elif args.preset in ("zipdepth-final-480x270", "zipdepth-optimized-480x270") and normalized_outputs:
        guided_outputs = {
            key: nightfall_guided_upsample(
                depth, guide_outputs[key], source_img, 480, 270
            )
            for key, depth in normalized_outputs.items()
        }
        comparison_gray = []
        comparison_color = []
        for key in selected_models:
            if key not in guided_outputs:
                continue
            guided = guided_outputs[key]
            label = DISPLAY_NAMES.get(key, key)
            gray = to_gray_png(guided)
            color = to_color_png(guided)
            gray.save(run_dir / f"{key}_guided_480x270_gray.png")
            color.save(run_dir / f"{key}_guided_480x270_color.png")
            comparison_gray.append((label, gray.convert("RGB")))
            comparison_color.append((label, color))
        normalized_outputs = guided_outputs

    if selected_models and normalized_outputs:
        # Head-comparison models may expose different native output sizes
        # (Direct-v1 is 192x192 while the learned heads return 384x384).
        # Enlarge smaller maps with nearest sampling for common-size metrics:
        # this preserves the information actually present in the model output
        # instead of making Direct look artificially smoother or sharper.
        comparison_outputs = {}
        comparison_size = next(iter(normalized_outputs.values())).shape
        for key, value in normalized_outputs.items():
            if value.shape != comparison_size:
                value = np.asarray(
                    Image.fromarray(value.astype(np.float32), mode="F").resize(
                        (comparison_size[1], comparison_size[0]),
                        Image.Resampling.NEAREST,
                    ),
                    dtype=np.float32,
                )
            comparison_outputs[key] = value
        edges = {key: edge_magnitude(value)
                 for key, value in comparison_outputs.items()}
        all_edges = np.concatenate([value.reshape(-1) for value in edges.values()])
        edge_scale = max(float(np.percentile(all_edges, 99.5)), 1e-6)
        comparison_edges = []
        for key in selected_models:
            if key not in edges:
                continue
            visual = np.clip(edges[key] / edge_scale, 0.0, 1.0)
            comparison_edges.append((
                DISPLAY_NAMES.get(key, key), to_gray_png(visual).convert("RGB")
            ))
        comparison_sheet(source_img, comparison_edges,
                         run_dir / "comparison_edges.png")

        if args.preset == "zipdepth-direct-v2":
            reference_key = "standard_v1_final"
        elif args.preset == "zipdepth-256-heads":
            reference_key = "edgepad_384_linear_480"
        elif args.preset == "zipdepth-edgepad-production":
            reference_key = "edgepad_384_production_480"
        elif args.preset == "zipdepth-edgepad-widescreen":
            reference_key = "edgepad_square_guided_480"
        elif args.preset == "zipdepth-resample-384":
            reference_key = "resample_384_linear"
        else:
            reference_key = "zipdepth_384_standard_v1"
        if reference_key in normalized_outputs:
            reference = comparison_outputs[reference_key]
            reference_edges = edges[reference_key]
            quality_metrics = {}
            for key, depth in comparison_outputs.items():
                correlation = float(np.corrcoef(reference.reshape(-1),
                                                depth.reshape(-1))[0, 1])
                quality_metrics[key] = {
                    "normalized_mae_vs_standard_v1": float(
                        np.mean(np.abs(depth - reference))
                    ),
                    "edge_mae_vs_standard_v1": float(
                        np.mean(np.abs(edges[key] - reference_edges))
                    ),
                    "correlation_vs_standard_v1": correlation,
                    "mean_edge_strength": float(np.mean(edges[key])),
                }
            summary["quality_metrics"] = quality_metrics

    with open(run_dir / "summary.json", "w") as f:
        json.dump(summary, f, indent=2)
    with open(run_dir / "timings.txt", "w") as f:
        f.write("\n".join(lines) + "\n")

    if selected_models and ok_results:
        comparison_sheet(source_img, comparison_gray, run_dir / "comparison_gray.png")
        comparison_sheet(source_img, comparison_color, run_dir / "comparison_color.png")

    print()
    print(f"Done. PNGs + summary.json + timings.txt written to {run_dir}")


if __name__ == "__main__":
    main()
