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

import json
import struct
import sys
import time
import uuid
from pathlib import Path

import numpy as np
from PIL import Image
from ai_edge_litert.interpreter import Interpreter

SCRIPT_DIR = Path(__file__).resolve().parent

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


def resize_rgb(img: Image.Image, size: int) -> np.ndarray:
    """High-quality resize to (size, size, 3) float32 RGB in 0..1 - stands in
    for the on-device box-filtered GPU downscale (see module docstring)."""
    resized = img.resize((size, size), Image.LANCZOS)
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
    raise ValueError(f"Can't infer family for model key '{model_key}' - "
                      f"expected it to start with midas/depth_anything/yolo26")


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
    except Exception as e:
        result["error"] = f"invoke failed: {e}"
        return result
    result["infer_time_ms"] = round((time.time() - t_infer_start) * 1000, 1)
    result["size"] = size

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
    return result


def main():
    input_path = Path(sys.argv[1]) if len(sys.argv) > 1 else SCRIPT_DIR / "eg_input_1.png"
    if not input_path.exists():
        print(f"Input image not found: {input_path}")
        sys.exit(1)

    settings = load_settings()
    source_img = load_source_image(input_path)

    output_dir = SCRIPT_DIR / "output"
    output_dir.mkdir(exist_ok=True)
    run_id = time.strftime("%H%M%S") + "_" + uuid.uuid4().hex[:4]
    run_dir = output_dir / f"{run_id}"
    run_dir.mkdir()

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
    header = f"{'model':<32} {'size':>5} {'load_ms':>8} {'infer_ms':>9} {'total_ms':>9} {'raw_min':>10} {'raw_max':>10} {'raw_mean':>10} {'raw_std':>10}"
    emit(header)
    emit("-" * len(header))

    run_wall_start = time.time()

    ok_results = []
    failed_results = []

    for model_key, cfg in settings["models"].items():
        if not cfg.get("enabled", True):
            continue
        result = run_one_model(model_key, cfg, settings, source_img)

        if "error" in result:
            failed_results.append(result)
            continue

        normalized = result.pop("_normalized")
        gray_path = run_dir / f"{model_key}_gray.png"
        color_path = run_dir / f"{model_key}_color.png"
        to_gray_png(normalized).save(gray_path)
        to_color_png(normalized).save(color_path)

        total_ms = result["load_time_ms"] + result["infer_time_ms"]
        result["total_time_ms"] = round(total_ms, 1)
        ok_results.append(result)

    # Ordered by infer_ms ascending - that's the steady-state per-frame cost
    # we actually care about (load_ms is a one-time startup cost, see the
    # header comment above). Failures sort last since they have no infer_ms.
    ok_results.sort(key=lambda r: r["infer_time_ms"])

    for result in ok_results:
        emit(f"{result['model']:<32} {result['size']:>5} {result['load_time_ms']:>8.1f} "
             f"{result['infer_time_ms']:>9.1f} {result['total_time_ms']:>9.1f} {result['raw_min']:>10.4f} "
             f"{result['raw_max']:>10.4f} {result['raw_mean']:>10.4f} {result['raw_std']:>10.4f}")
        summary["results"].append(result)

    for result in failed_results:
        emit(f"{result['model']:<32} {'':>5} {'':>8} {'':>9} {'':>9}  FAILED: {result['error']}")
        summary["results"].append({k: v for k, v in result.items() if k != "_normalized"})

    run_wall_ms = round((time.time() - run_wall_start) * 1000, 1)
    emit()
    emit(f"Total wall time for this run: {run_wall_ms}ms")
    summary["run_wall_time_ms"] = run_wall_ms

    with open(run_dir / "summary.json", "w") as f:
        json.dump(summary, f, indent=2)
    with open(run_dir / "timings.txt", "w") as f:
        f.write("\n".join(lines) + "\n")

    print()
    print(f"Done. PNGs + summary.json + timings.txt written to {run_dir}")


if __name__ == "__main__":
    main()
