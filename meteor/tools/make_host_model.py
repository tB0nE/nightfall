#!/usr/bin/env python3
"""Builds a Meteor host depth model from a ZipDepth EdgePad ONNX export.

EdgePad graphs end in a packed [1, 4, H/2, W/2] tensor (the four sub-pixels of
each 2x2 block) that DepthEstimator.java's unpack2x2Depth() interleaves and
clamps at zero. This appends the same step to the ONNX graph (DepthToSpace,
then Relu), so Meteor gets a plain [1, 1, H, W] depth map, and embeds the
weights in one file:

    python meteor/tools/make_host_model.py \\
        student_512x288_edgepad.onnx \\
        ~/.local/share/nightfall-meteor/models/zipdepth_wide_512x288.onnx \\
        student_512x288_edgepad_float16.tflite

With a matching .tflite (the third argument; the Quest's EdgePad-384 by
default), it checks the result against it on a random input when
ai_edge_litert is installed.
"""

import os
import sys

import numpy as np
import onnx
from onnx import helper


def build(source, dest):
    model = onnx.load(source)  # loads the external weights too
    graph = model.graph
    if len(graph.output) != 1:
        sys.exit(f"expected one output, found {len(graph.output)}")
    packed = graph.output[0]
    dims = [d.dim_value for d in packed.type.tensor_type.shape.dim]
    if len(dims) != 4 or dims[1] != 4:
        sys.exit(f"expected a packed [1, 4, H/2, W/2] output, found {dims}")
    _, _, h, w = dims
    # The packed tensor is renamed, so the final output can keep its name.
    for node in graph.node:
        node.output[:] = ["depth_packed" if o == packed.name else o for o in node.output]
        node.input[:] = ["depth_packed" if i == packed.name else i for i in node.input]
    # DCR order: channel (i * 2 + j) goes to row offset i, column offset j,
    # i.e. top-left, top-right, bottom-left, bottom-right as on the Quest.
    graph.node.append(helper.make_node("DepthToSpace", ["depth_packed"], ["depth_unclamped"], blocksize=2, mode="DCR"))
    graph.node.append(helper.make_node("Relu", ["depth_unclamped"], ["depth"]))
    del graph.output[:]
    graph.output.append(helper.make_tensor_value_info("depth", onnx.TensorProto.FLOAT, [1, 1, h * 2, w * 2]))
    onnx.checker.check_model(model)
    onnx.save(model, dest)
    print(f"{dest}: [1, 1, {h * 2}, {w * 2}] output, {os.path.getsize(dest) // 1_000_000} MB")


def verify(dest, tflite):
    import onnxruntime as ort

    try:
        from ai_edge_litert.interpreter import Interpreter
    except ImportError:
        print("ai_edge_litert not installed; skipped the check against the Quest model")
        return
    session = ort.InferenceSession(dest, providers=["CPUExecutionProvider"])
    shape = session.get_inputs()[0].shape
    rgb = np.random.default_rng(1).random((shape[2], shape[3], 3), dtype=np.float32)
    if not os.path.exists(tflite):
        print(f"{tflite} not found; skipped the check against the .tflite model")
        return
    ours = session.run(None, {session.get_inputs()[0].name: rgb.transpose(2, 0, 1)[None]})[0][0, 0]
    interp = Interpreter(model_path=tflite)
    interp.allocate_tensors()
    interp.set_tensor(interp.get_input_details()[0]["index"], rgb[None])
    interp.invoke()
    packed = interp.get_tensor(interp.get_output_details()[0]["index"])[0]
    quest = np.empty_like(ours)
    quest[0::2, 0::2], quest[0::2, 1::2] = packed[:, :, 0], packed[:, :, 1]
    quest[1::2, 0::2], quest[1::2, 1::2] = packed[:, :, 2], packed[:, :, 3]
    quest = np.maximum(quest, 0)
    corr = np.corrcoef(ours.ravel(), quest.ravel())[0, 1]
    worst = np.abs(ours - quest).max() / (quest.max() - quest.min())
    print(f"vs the .tflite: correlation {corr:.9f}, worst difference {worst * 100:.4f}% of range")
    if corr < 0.9999:
        sys.exit("doesn't match the .tflite")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    build(sys.argv[1], os.path.expanduser(sys.argv[2]))
    here = os.path.dirname(os.path.abspath(__file__))
    tflite = sys.argv[3] if len(sys.argv) == 4 else os.path.join(
        here, "..", "..", "models", "zipdepth-base-384-standard-packed-conv4-reduceconv-edgepad-gpu.tflite")
    verify(os.path.expanduser(sys.argv[2]), os.path.expanduser(tflite))
