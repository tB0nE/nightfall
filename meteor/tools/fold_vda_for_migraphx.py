#!/usr/bin/env python3
"""Make the MIGraphX VDA package from the published VDA-S ONNX graphs.

MIGraphX has no cubic Resize. The only one in VDA-S resizes the constant ViT
position-embedding grid to the 518x294 patch layout (37x21), so its result is
folded into an initializer: the graphs compute exactly the same thing.

Input: the meteor-vda-s-518x294 release files (vda_s_518x294_step.onnx,
vda_s_518x294_cold.onnx, vda_s_518x294.onnx.data) and the model's LICENSE.
Output: <out>/{step.onnx,step.onnx.data,cold.onnx,cold.onnx.data,LICENSE,manifest.json},
the layout Meteor's vda_migraphx_518x294 model expects. Prints the files and
SHA-256s for models/vda-vulkan-downloads.json.

Needs: onnx, onnxruntime (CPU) and numpy.
  tools/fold_vda_for_migraphx.py --source <dir> --license <LICENSE> --out <dir>
"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper, numpy_helper

CHECKPOINT_SHA256 = "13379300b739e659f076a59d52e9801bd8d38c541a7e71f73bbca4dcfb013609"


def is_cubic_resize(node):
    return node.op_type == "Resize" and any(a.name == "mode" and a.s == b"cubic" for a in node.attribute)


def fold(source: Path, out: Path, name: str):
    model = onnx.load(str(source))  # resolves the external data next to source
    graph = model.graph
    inputs = {i.name for i in graph.input}
    producer = {o: n for n in graph.node for o in n.output}

    def depends_on_input(value, seen):
        if value in inputs:
            return True
        if value in seen or value not in producer:
            return False
        seen.add(value)
        return any(depends_on_input(v, seen) for v in producer[value].input if v)

    cubic = [n for n in graph.node if is_cubic_resize(n)]
    if len(cubic) != 1:
        raise SystemExit(f"{source.name}: expected one cubic Resize, found {len(cubic)}")
    node = cubic[0]
    if depends_on_input(node.output[0], set()):
        raise SystemExit(f"{source.name}: the cubic Resize depends on a graph input; refusing to fold it")

    # Evaluate the constant once on the CPU, from the untouched graph.
    probe = onnx.ModelProto()
    probe.CopyFrom(model)
    probe.graph.output.append(helper.make_tensor_value_info(node.output[0], TensorProto.FLOAT, None))
    session = ort.InferenceSession(probe.SerializeToString(), providers=["CPUExecutionProvider"])
    feeds = {i.name: np.zeros(i.shape, np.float32) for i in session.get_inputs()}
    value = session.run([node.output[0]], feeds)[0].astype(np.float32)
    print(f"{source.name}: folded {node.name} -> {list(value.shape)}")

    graph.node.remove(node)
    graph.initializer.append(numpy_helper.from_array(value, node.output[0]))
    while True:  # drop whatever only fed the folded node
        used = {v for n in graph.node for v in n.input} | {o.name for o in graph.output}
        dead = [n for n in graph.node if not any(o in used for o in n.output)]
        if not dead:
            break
        for n in dead:
            graph.node.remove(n)
    used = {v for n in graph.node for v in n.input}
    for t in [t for t in graph.initializer if t.name not in used]:
        graph.initializer.remove(t)
    onnx.checker.check_model(model, full_check=False)
    onnx.save(model, str(out / f"{name}.onnx"), save_as_external_data=True,
              all_tensors_to_one_file=True, location=f"{name}.onnx.data")


def sha256(path: Path):
    digest = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path, required=True, help="folder with the vda_s_518x294_* release files")
    parser.add_argument("--license", type=Path, required=True, help="the VDA-S LICENSE (Apache-2.0)")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for name in ("step", "cold"):
        fold(args.source / f"vda_s_518x294_{name}.onnx", args.out, name)
    shutil.copyfile(args.license, args.out / "LICENSE")
    files = ["step.onnx", "step.onnx.data", "cold.onnx", "cold.onnx.data"]
    manifest = {"schema": 1, "width": 518, "height": 294, "checkpoint_sha256": CHECKPOINT_SHA256,
                "files": {f: sha256(args.out / f) for f in files}}
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for f in files + ["LICENSE", "manifest.json"]:
        p = args.out / f
        print(f"{f}\t{p.stat().st_size}\t{sha256(p)}")


if __name__ == "__main__":
    main()
