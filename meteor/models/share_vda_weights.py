#!/usr/bin/env python3
"""Repacks Video Depth Anything Small's two graphs so they share one weights file.

usage: share_vda_weights.py <step.onnx> <cold_start.onnx> [--out <dir>]

Writes, into --out (default: the current folder):
- vda_s_518x294.onnx.data: every weight, stored once (about 116 MB);
- vda_s_518x294_step.onnx: the recurrent step graph (about 10 MB, mostly
  its temporal position constants);
- vda_s_518x294_cold.onnx: the cold-start graph (under 1 MB).

The researcher's export (nightfall-temporal-zipdepth,
experiments/video_depth_anything_small/export_streaming_onnx.py) writes two
self-contained graphs. The cold start's weights are all in the step's too,
so the pair downloads the same 113 MB twice. Here each weight of 1 KiB or
more moves into the data file, matched by content, and both graphs point at
it through ONNX external data. Nothing else changes: the same nodes, the
same values. TensorRT's parseFromFile and ONNX Runtime both read the data
file from beside the graph.

The output is the same bytes on every run, so the release's SHA-256s can be
checked by running it again. Needs the onnx package (`pip install onnx`).
"""
import argparse
import hashlib
import sys
from pathlib import Path

import onnx
from onnx import TensorProto

DATA = "vda_s_518x294.onnx.data"
STEP = "vda_s_518x294_step.onnx"
COLD = "vda_s_518x294_cold.onnx"
MIN_BYTES = 1024
ALIGN = 64

# The fields a tensor can hold its values in, besides raw_data.
TYPED_FIELDS = ("float_data", "int32_data", "string_data", "int64_data", "double_data", "uint64_data")


def raw_bytes(tensor):
    return onnx.numpy_helper.to_array(tensor).tobytes()


def externalise(graph, blob, offsets):
    """Points the graph's large initializers at the shared data, adding new
    values to it. Returns the bytes this graph moved out."""
    moved = 0
    for tensor in graph.initializer:
        data = raw_bytes(tensor)
        if len(data) < MIN_BYTES or tensor.data_type == TensorProto.STRING:
            continue
        key = hashlib.sha256(tensor.data_type.to_bytes(4, "little") + data).digest()
        if key not in offsets:
            blob.extend(b"\0" * (-len(blob) % ALIGN))
            offsets[key] = len(blob)
            blob.extend(data)
        for field in ("raw_data", *TYPED_FIELDS):
            tensor.ClearField(field)
        del tensor.external_data[:]
        tensor.data_location = TensorProto.EXTERNAL
        for k, v in (("location", DATA), ("offset", str(offsets[key])), ("length", str(len(data)))):
            entry = tensor.external_data.add()
            entry.key, entry.value = k, v
        moved += len(data)
    return moved


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("step", type=Path)
    parser.add_argument("cold", type=Path)
    parser.add_argument("--out", type=Path, default=Path("."))
    args = parser.parse_args()
    if sys.byteorder != "little":
        sys.exit("ONNX external data is little-endian; run this on a little-endian machine")

    step = onnx.load(args.step)
    cold = onnx.load(args.cold)
    blob = bytearray()
    offsets = {}
    step_moved = externalise(step.graph, blob, offsets)
    cold_moved = externalise(cold.graph, blob, offsets)
    shared = len(offsets)

    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / DATA).write_bytes(bytes(blob))
    for model, name in ((step, STEP), (cold, COLD)):
        (args.out / name).write_bytes(model.SerializeToString(deterministic=True))
        onnx.checker.check_model(str(args.out / name))

    total = sum(p.stat().st_size for p in map(args.out.joinpath, (DATA, STEP, COLD)))
    before = args.step.stat().st_size + args.cold.stat().st_size
    print(f"{shared} distinct weights, {len(blob) / 1e6:.1f} MB in {DATA}")
    print(f"step moved {step_moved / 1e6:.1f} MB, cold start {cold_moved / 1e6:.1f} MB")
    print(f"{before / 1e6:.1f} MB before, {total / 1e6:.1f} MB after")
    for name in (DATA, STEP, COLD):
        path = args.out / name
        print(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.stat().st_size:>11}  {name}")


if __name__ == "__main__":
    main()
