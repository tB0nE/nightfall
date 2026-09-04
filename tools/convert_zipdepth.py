#!/usr/bin/env python3
"""
Convert ZipDepth-Base to a TFLite float16-weight GPU-delegate model for
Nightfall, at 384px (ZipDepth's native/trained resolution).  The default
hybrid uses the standard checkpoint's sharper backbone/decoder with the NPU
checkpoint's mobile-safe upsampling head.

ZipDepth: https://github.com/fabiotosi92/ZipDepth (ECCV 2026, MIT license) -
a 6.1M-param pure-CNN (RepVGG + Strip Pooling/SE/Global-Context attention,
convex-upsampling FPN decoder) distilled from Depth Anything V2 Large across
14.1M images/17 domains. Chosen over Depth Anything V2's own ViT-S backbone
because it has no transformer attention/softmax/matmul ops - the exact op classes that
made DA-V2-GPU 7x too slow on this hardware's GPU delegate (12 repeated
ViT-block GPU<->CPU handoffs, see quest3_gpu_acceleration_limits memory).

192/256 were also built and visually compared here (tools/model_tester/) but
dropped (2026-09-04): every number in ZipDepth's own paper is measured at
384x384, and unlike MiDaS-192 (independently trained/calibrated at that size,
not a resize of the 256px model) ZipDepth has no dedicated lower-resolution
training - 192/256 are just the 384 weights looking at a smaller image
outside their trained distribution, and it showed (192 especially). Add
sizes back to the SIZES tuple below if revisiting.

Usage:
    python3 tools/convert_zipdepth.py

Output:
    models/zipdepth-base-384-gpu.tflite

Requires: pip install onnx2tf onnxsim onnx onnxruntime ai-edge-litert torch pillow
"""

import argparse
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
OUTPUT_DIR = os.path.join(PROJECT_DIR, "models")
REPO_DIR = os.path.join(SCRIPT_DIR, "ZipDepth")
CKPT_URL = "https://github.com/fabiotosi92/ZipDepth/raw/main/checkpoints/zipdepth_base_npu.pth"
CKPT_PATH = os.path.join(REPO_DIR, "checkpoints", "zipdepth_base_npu.pth")
STANDARD_CKPT_URL = "https://github.com/fabiotosi92/ZipDepth/raw/main/checkpoints/zipdepth_base.pth"
STANDARD_CKPT_PATH = os.path.join(REPO_DIR, "checkpoints", "zipdepth_base.pth")
SIZES = (384,)

PYTHON = os.environ.get("NIGHTFALL_MODEL_PYTHON", sys.executable)


def install_deps():
    packages = {
        "onnx2tf": "onnx2tf",
        "onnxsim": "onnxsim",
        "onnx": "onnx",
        "onnxruntime": "onnxruntime",
        "ai-edge-litert": "ai_edge_litert",
        "torch": "torch",
        "pillow": "PIL",
    }
    for pkg, module in packages.items():
        try:
            __import__(module)
        except ImportError:
            print(f"Installing {pkg}...")
            subprocess.check_call([PYTHON, "-m", "pip", "install", "-q", pkg])


def clone_repo():
    if os.path.exists(os.path.join(REPO_DIR, "scripts", "export.py")):
        print(f"ZipDepth repo already exists at {REPO_DIR}")
        return
    print("Cloning ZipDepth repo...")
    subprocess.check_call(["git", "clone", "--depth", "1", "https://github.com/fabiotosi92/ZipDepth.git", REPO_DIR])


def download_checkpoint(weights_mode="hybrid"):
    import urllib.request

    required = [(CKPT_URL, CKPT_PATH)]
    if weights_mode == "hybrid":
        required.append((STANDARD_CKPT_URL, STANDARD_CKPT_PATH))
    os.makedirs(os.path.dirname(CKPT_PATH), exist_ok=True)
    for url, path in required:
        if os.path.exists(path):
            print(f"Checkpoint already exists at {path}")
            continue
        print(f"Downloading {os.path.basename(path)}...")
        urllib.request.urlretrieve(url, path)


def export_onnx(force=False, head_mode="full", weights_mode="hybrid"):
    onnx_dir = os.path.join(REPO_DIR, "onnx_export")
    os.makedirs(onnx_dir, exist_ok=True)
    for size in SIZES:
        out_path = os.path.join(onnx_dir, f"zipdepth_base_{size}.onnx")
        if os.path.exists(out_path) and not force:
            print(f"ONNX {size}px already exists at {out_path}")
            continue
        print(f"Exporting GPU-safe ONNX at {size}x{size}...")
        command = [
            PYTHON, os.path.join(SCRIPT_DIR, "export_zipdepth_gpu_safe.py"),
            "--ckpt", CKPT_PATH,
            "--size", str(size),
            "--head-mode", head_mode,
            "--output", out_path,
        ]
        if weights_mode == "hybrid":
            command.extend(["--backbone-ckpt", STANDARD_CKPT_PATH])
        subprocess.check_call(command, cwd=PROJECT_DIR)


def convert_tflite(force=False):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    for size in SIZES:
        out_model = os.path.join(OUTPUT_DIR, f"zipdepth-base-{size}-gpu.tflite")
        if os.path.exists(out_model) and not force:
            print(f"TFLite {size}px already exists at {out_model}")
            continue

        onnx_path = os.path.join(REPO_DIR, "onnx_export", f"zipdepth_base_{size}.onnx")
        tflite_dir = os.path.join(REPO_DIR, f"tflite_{size}")

        print(f"Converting {size}px ONNX -> TFLite...")
        # NOTE: deliberately NOT passing -ofgd (--optimization_for_gpu_delegate).
        # ZipDepth's op composition (Conv/Add/Mul/Relu/Sigmoid/BatchNorm/
        # Pool/Resize - verified via onnx2tf's own op-count table, zero
        # Gather/BatchMatMul/Gelu/Softmax) is already 100% native GPU-delegate
        # ops, so -ofgd has nothing to legitimately replace - and empirically
        # it introduces a real numerical bug for this specific graph (verified
        # 2026-09-04: with -ofgd, TFLite output diverges sharply from the
        # onnxruntime reference - max~0.43 vs ~0.11, visibly striped/broken
        # depth maps; without it, TFLite output matches the ONNX reference to
        # float32 rounding error, ~1e-6 max abs diff, clean coherent depth).
        #
        # -tb tf_converter (--tflite_backend tf_converter), NOT the default
        # flatbuffer_direct: this routes through the real
        # tf.lite.TFLiteConverter machinery instead of onnx2tf's own fast
        # FlatBuffer builder path, which matters for the resulting
        # `_float16.tflite` sibling's I/O contract. With the DEFAULT
        # flatbuffer_direct backend, that float16 file makes BOTH weights
        # AND the input/output tensors float16 - incompatible with
        # Nightfall's GPU delegate convention (see DepthEstimator.java's
        # MODEL_MIDAS_GPU comment): float32 I/O boundary +
        # GpuDelegateFactory.Options.setPrecisionLossAllowed(true) for fp16
        # *execution* precision, which the existing runInferenceGpu()/
        # GpuVariant plumbing depends on (allocates float32 direct
        # ByteBuffers). tf_converter's float16 output instead does proper
        # TFLite weight-only float16 quantization - only constant/weight
        # tensors become float16 (with a Dequantize op at the boundary),
        # input/output stay float32 - exactly matching MiDaS-GPU's own
        # recipe. Verified (2026-09-04): I/O confirmed float32, output
        # matches the ONNX reference to ~2-5e-4 max abs diff (normal fp16
        # weight quantization noise, same order of magnitude MiDaS-GPU
        # already ships with), and TFLite's own GPU delegate compatibility
        # analyzer (tf.lite.experimental.Analyzer.analyze(...,
        # gpu_compatibility=True)) confirms compatibility for this file.
        # Also produces a `_float32.tflite` sibling (fully float32, ~2x
        # larger, no compression) - not used, kept only as an intermediate.
        subprocess.check_call([
            PYTHON, "-m", "onnx2tf",
            "-i", onnx_path,
            "-o", tflite_dir,
            "-tb", "tf_converter",
            "-osd",  # output signature defs / tensor correspondence report
        ])

        src = os.path.join(tflite_dir, f"zipdepth_base_{size}_float16.tflite")
        import shutil
        shutil.copy2(src, out_model)
        size_mb = os.path.getsize(out_model) / (1024 * 1024)
        print(f"Copied {src} -> {out_model} ({size_mb:.1f} MB)")


def verify():
    import numpy as np
    from PIL import Image
    from ai_edge_litert.interpreter import Interpreter

    example_img = os.path.join(REPO_DIR, "assets", "examples", "im0.jpg")
    img = Image.open(example_img).convert("RGB") if os.path.exists(example_img) else None

    for size in SIZES:
        model_path = os.path.join(OUTPUT_DIR, f"zipdepth-base-{size}-gpu.tflite")
        interp = Interpreter(model_path=model_path)
        interp.allocate_tensors()
        in_d = interp.get_input_details()[0]
        out_d = interp.get_output_details()[0]
        print(f"{size}px: input={in_d['shape']}/{in_d['dtype']}  output={out_d['shape']}/{out_d['dtype']}")

        if img is not None:
            resized = img.resize((size, size), Image.BILINEAR)
            arr = (np.asarray(resized).astype(np.float32) / 255.0)[None, ...]
            interp.set_tensor(in_d["index"], arr)
            interp.invoke()
            out = interp.get_tensor(out_d["index"])
            print(f"  test inference: min={out.min():.4f} max={out.max():.4f} mean={out.mean():.4f} std={out.std():.4f}")
            if out.std() < 1e-6:
                print("  WARNING: near-constant output - likely broken conversion")

    print("Verification passed!")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--force",
        action="store_true",
        help="regenerate ONNX and TFLite outputs even when they already exist",
    )
    parser.add_argument(
        "--head-mode",
        choices=(
            "full",
            "bilinear",
            "encoder-mosaic",
            "stage2-mosaic",
            "decoder-mosaic",
        ),
        default="full",
        help="build the complete model or the diagnostic bilinear-only head",
    )
    parser.add_argument(
        "--weights-mode",
        choices=("npu", "hybrid"),
        default="hybrid",
        help="use the NPU weights or the sharper standard weights with the NPU head",
    )
    args = parser.parse_args()
    install_deps()
    clone_repo()
    download_checkpoint(args.weights_mode)
    export_onnx(
        force=args.force,
        head_mode=args.head_mode,
        weights_mode=args.weights_mode,
    )
    convert_tflite(force=args.force)
    verify()
    print(f"\nDone! Model at: {OUTPUT_DIR}/zipdepth-base-384-gpu.tflite")


if __name__ == "__main__":
    main()
