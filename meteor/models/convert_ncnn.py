#!/usr/bin/env python3
"""Converts a single-frame depth model (EdgePad) from ONNX to ncnn for Meteor.

usage: convert_ncnn.py <model.onnx>... [--out <dir>]

Writes <name>.ncnn.param and <name>.ncnn.bin next to each model, or into
--out. Needs pnnx (`pip install pnnx`).

- The weights stay fp32 (`fp16=0`). Meteor runs them with fp16 storage and
  fp32 arithmetic; fp16 weights add error.
- pnnx can't map ONNX DepthToSpace and leaves an unknown layer. ncnn's
  PixelShuffle is the same operation (mode 1 is DCR, 0 is CRD), so the
  layer is rewritten with the block size and mode pnnx recorded.
- The input size goes on the Input layer (0=w 1=h 2=c), where Meteor reads
  it.

A layer ncnn doesn't have makes Meteor's load fail with ncnn's "layer ...
not exists or registered"; check a retrained model with the parity test
(see README.md).
"""
import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def input_shape(onnx_path):
    """The model's 1x3xHxW input, read from the ONNX file with the onnx package
    if it's installed, else from the WxH in the file name."""
    try:
        import onnx

        dims = onnx.load(str(onnx_path), load_external_data=False).graph.input[0].type.tensor_type.shape.dim
        shape = [d.dim_value for d in dims]
        if len(shape) == 4 and shape[:2] == [1, 3] and all(shape):
            return shape[3], shape[2]
    except ImportError:
        pass
    match = re.search(r"(\d+)x(\d+)", onnx_path.stem)
    if match:
        return int(match.group(1)), int(match.group(2))
    match = re.search(r"_(\d+)$", onnx_path.stem)
    if match:
        return int(match.group(1)), int(match.group(1))
    sys.exit(f"{onnx_path}: can't tell the input size (install the onnx package)")


def convert(onnx_path, out_dir, pnnx):
    width, height = input_shape(onnx_path)
    name = onnx_path.stem
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        model = work / "model.onnx"
        shutil.copyfile(onnx_path, model)
        result = subprocess.run(
            [pnnx, str(model), f"inputshape=[1,3,{height},{width}]", "fp16=0"],
            cwd=work, capture_output=True, text=True,
        )
        param_path, bin_path = work / "model.ncnn.param", work / "model.ncnn.bin"
        if result.returncode != 0 or not param_path.exists():
            sys.exit(f"{onnx_path}: pnnx failed\n{result.stdout}{result.stderr}")

        # Block size and mode of each DepthToSpace, from pnnx's own graph.
        shuffles = {}
        for line in (work / "model.pnnx.param").read_text().splitlines():
            fields = line.split()
            if fields and fields[0] == "DepthToSpace":
                attrs = dict(f.split("=", 1) for f in fields if "=" in f and not f.startswith("#"))
                shuffles[fields[1]] = (int(attrs["blocksize"]), 1 if attrs.get("mode", "DCR") == "DCR" else 0)

        lines = param_path.read_text().splitlines()
        for i, line in enumerate(lines):
            fields = line.split()
            if not fields:
                continue
            if fields[0] == "DepthToSpace":
                block, mode = shuffles[fields[1]]
                lines[i] = f"{'PixelShuffle':<24} {' '.join(fields[1:])} 0={block} 1={mode}"
            elif fields[0] == "Input":
                lines[i] = f"{line} 0={width} 1={height} 2=3"

        out_dir.mkdir(parents=True, exist_ok=True)
        (out_dir / f"{name}.ncnn.param").write_text("\n".join(lines) + "\n")
        shutil.copyfile(bin_path, out_dir / f"{name}.ncnn.bin")
    size = (out_dir / f"{name}.ncnn.bin").stat().st_size / 2**20
    print(f"{name}: {width}x{height}, {len(shuffles)} DepthToSpace rewritten, {size:.1f} MiB of weights")




def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("models", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, help="output folder (default: next to each model)")
    args = parser.parse_args()
    pnnx = shutil.which("pnnx") or str(Path(sys.executable).with_name("pnnx"))
    if not Path(pnnx).exists() and not shutil.which(pnnx):
        sys.exit("pnnx not found (pip install pnnx)")
    for model in args.models:
        convert(model, args.out or model.parent, pnnx)


if __name__ == "__main__":
    main()
