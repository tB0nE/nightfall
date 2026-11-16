#!/usr/bin/env python3
"""
Convert Depth Anything V2 Small to TFLite (int8 quantized) for Nightfall.

Usage:
    python3 tools/convert_depth_anything_v2.py

Output:
    android/src/main/assets/depth-anything-v2-small.tflite

Requires: pip install onnx2tf sng4onnx onnxsim onnx
"""

import sys
import os
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
OUTPUT_DIR = os.path.join(PROJECT_DIR, "android", "src", "main", "assets")
OUTPUT_MODEL = os.path.join(OUTPUT_DIR, "depth-anything-v2-small.tflite")
ONNX_PATH = os.path.join(PROJECT_DIR, "tools", "depth_anything_v2.onnx")
MODEL_SIZE = 256

PYTHON = os.path.join(os.path.expanduser("~"), ".pyenv/versions/3.12.2/bin/python3")


def install_deps():
    packages = ["onnx2tf", "sng4onnx", "onnxsim", "onnx"]
    for pkg in packages:
        try:
            __import__(pkg.replace("-", "_"))
        except ImportError:
            print(f"Installing {pkg}...")
            subprocess.check_call([PYTHON, "-m", "pip", "install", "-q", pkg])


def download_model():
    weight_dir = os.path.join(PROJECT_DIR, "tools", "depth_anything_v2_weights")
    weight_path = os.path.join(weight_dir, "depth_anything_v2_vits.pth")
    if os.path.exists(weight_path):
        print(f"Weights already exist at {weight_path}")
        return weight_path

    os.makedirs(weight_dir, exist_ok=True)
    print("Downloading Depth Anything V2 Small weights...")
    import urllib.request
    url = "https://huggingface.co/depth-anything/Depth-Anything-V2-Small/resolve/main/depth_anything_v2_vits.pth"
    urllib.request.urlretrieve(url, weight_path)
    print(f"Downloaded to {weight_path}")
    return weight_path


def install_depth_anything():
    repo_dir = os.path.join(PROJECT_DIR, "tools", "Depth-Anything-V2")
    if os.path.exists(os.path.join(repo_dir, "depth_anything_v2", "dpt.py")):
        print(f"Depth-Anything-V2 repo already exists at {repo_dir}")
        sys.path.insert(0, repo_dir)
        return

    print("Cloning Depth-Anything-V2 repo...")
    subprocess.check_call([
        "git", "clone", "--depth", "1",
        "https://github.com/DepthAnything/Depth-Anything-V2.git",
        repo_dir
    ])
    sys.path.insert(0, repo_dir)


def export_onnx(weight_path):
    if os.path.exists(ONNX_PATH):
        print(f"ONNX model already exists at {ONNX_PATH}")
        return

    import torch
    import torch.nn as nn

    from depth_anything_v2.dpt import DepthAnythingV2

    print("Loading Depth Anything V2 Small model...")
    model_config = dict(encoder='vits', features=64, out_channels=[48, 96, 192, 384])
    model = DepthAnythingV2(**model_config)
    model.load_state_dict(torch.load(weight_path, map_location="cpu"))
    model.eval()

    mean = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
    std = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)

    class Wrapper(nn.Module):
        def __init__(self, core, mean, std):
            super().__init__()
            self.core = core
            self.register_buffer("mean", mean)
            self.register_buffer("std", std)

        def forward(self, x):
            x = x.permute(0, 3, 1, 2)
            x = (x - self.mean) / self.std
            d = self.core(x)
            # Current Depth-Anything-V2 returns [N, H, W]; older checkouts [N, 1, H, W].
            d = d.unsqueeze(-1) if d.dim() == 3 else d.permute(0, 2, 3, 1)
            return d

    wrapper = Wrapper(model, mean, std)
    wrapper.eval()

    dummy = torch.randn(1, MODEL_SIZE, MODEL_SIZE, 3)

    print("Exporting to ONNX...")
    torch.onnx.export(
        wrapper, dummy, ONNX_PATH,
        opset_version=17,
        input_names=["input"],
        output_names=["output"],
        dynamic_axes=None,
        do_constant_folding=True,
    )
    print(f"ONNX exported to {ONNX_PATH}")


def simplify_onnx():
    import onnxsim
    import onnx

    print("Simplifying ONNX model...")
    model = onnx.load(ONNX_PATH)
    model_simplified, check = onnxsim.simplify(model)
    if check:
        onnx.save(model_simplified, ONNX_PATH)
        print("ONNX simplified successfully")
    else:
        print("WARNING: ONNX simplification failed, using unsimplified model")


def convert_tflite():
    if os.path.exists(OUTPUT_MODEL):
        print(f"TFLite model already exists at {OUTPUT_MODEL}")
        return

    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print("Converting ONNX to TFLite with int8 quantization...")
    print("This may take a few minutes...")

    cmd = [
        sys.executable, "-m", "onnx2tf",
        "-i", ONNX_PATH,
        "-o", os.path.join(PROJECT_DIR, "tools", "tflite_tmp"),
        "--quantization_type", "int8",
        "--quantization_calculator_type", "int8",
        "--qty_input_shape", f"1,{MODEL_SIZE},{MODEL_SIZE},3",
    ]

    try:
        subprocess.check_call(cmd)
    except subprocess.CalledProcessError as e:
        print(f"onnx2tf int8 failed ({e}), falling back to float16...")
        cmd_f16 = [
            sys.executable, "-m", "onnx2tf",
            "-i", ONNX_PATH,
            "-o", os.path.join(PROJECT_DIR, "tools", "tflite_tmp"),
        ]
        subprocess.check_call(cmd_f16)

    tflite_tmp = os.path.join(PROJECT_DIR, "tools", "tflite_tmp")
    for root, dirs, files in os.walk(tflite_tmp):
        for f in files:
            if f.endswith(".tflite"):
                src = os.path.join(root, f)
                import shutil
                shutil.copy2(src, OUTPUT_MODEL)
                print(f"Copied {src} -> {OUTPUT_MODEL}")
                size_mb = os.path.getsize(OUTPUT_MODEL) / (1024 * 1024)
                print(f"Model size: {size_mb:.1f} MB")
                return

    print("ERROR: No .tflite file found in output")
    sys.exit(1)


def verify():
    import numpy as np

    try:
        from ai_edge_litert.interpreter import Interpreter
    except ImportError:
        try:
            import tensorflow as tf
            interpreter = tf.lite.Interpreter(model_path=OUTPUT_MODEL)
        except ImportError:
            print("Cannot verify - no TFLite runtime available")
            print(f"Model exists at {OUTPUT_MODEL} ({os.path.getsize(OUTPUT_MODEL) / (1024*1024):.1f} MB)")
            return

    try:
        interpreter = Interpreter(model_path=OUTPUT_MODEL)
    except:
        import tensorflow as tf
        interpreter = tf.lite.Interpreter(model_path=OUTPUT_MODEL)

    interpreter.allocate_tensors()

    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()

    print(f"Input:  shape={input_details[0]['shape']}, dtype={input_details[0]['dtype']}")
    print(f"Output: shape={output_details[0]['shape']}, dtype={output_details[0]['dtype']}")

    test_input = np.random.rand(1, MODEL_SIZE, MODEL_SIZE, 3).astype(np.float32)
    interpreter.set_tensor(input_details[0]['index'], test_input)
    interpreter.invoke()
    output = interpreter.get_tensor(output_details[0]['index'])

    print(f"Test output: min={output.min():.4f}, max={output.max():.4f}, mean={output.mean():.4f}")
    print("Verification passed!")


def main():
    import argparse
    global MODEL_SIZE
    parser = argparse.ArgumentParser()
    parser.add_argument("--size", type=int, default=MODEL_SIZE,
                        help="square input size (the Linux ncnn model uses 252, a multiple of 14)")
    parser.add_argument("--onnx-only", action="store_true",
                        help="stop after the ONNX export (input for tools/convert_linux_depth_ncnn.py)")
    args = parser.parse_args()
    MODEL_SIZE = args.size
    if args.onnx_only:
        install_depth_anything()
        export_onnx(download_model())
        print(f"\nDone! ONNX at: {ONNX_PATH}")
        return
    install_deps()
    install_depth_anything()
    weight_path = download_model()
    export_onnx(weight_path)
    simplify_onnx()
    convert_tflite()
    verify()
    print(f"\nDone! Model at: {OUTPUT_MODEL}")


if __name__ == "__main__":
    main()
