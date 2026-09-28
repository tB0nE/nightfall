#!/usr/bin/env python3
"""Convert Nightfall's Linux GPU depth-model library for ncnn Vulkan."""

import argparse
import os
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ONNX_DIR = ROOT / "tools" / "ZipDepth" / "onnx_export"
MODEL_DIR = ROOT / "models"


def run_pnnx(pnnx: str, source: Path, prefix: Path, scratch: Path, force: bool) -> None:
    param = Path(f"{prefix}.ncnn.param")
    weights = Path(f"{prefix}.ncnn.bin")
    if not source.is_file():
        raise SystemExit(f"Missing conversion source: {source}")
    if not force and param.is_file() and weights.is_file():
        print(f"Already converted: {prefix}")
        return

    scratch.mkdir(parents=True, exist_ok=True)
    command = [
        pnnx,
        str(source),
        f"pnnxparam={scratch / 'model.pnnx.param'}",
        f"pnnxbin={scratch / 'model.pnnx.bin'}",
        f"pnnxpy={scratch / 'model_pnnx.py'}",
        f"pnnxonnx={scratch / 'model.pnnx.onnx'}",
        f"ncnnparam={param}",
        f"ncnnbin={weights}",
        f"ncnnpy={scratch / 'model_ncnn.py'}",
        "fp16=1",
    ]
    subprocess.run(command, check=True)


def convert(pnnx: str, size: int, force: bool, onnx_dir: Path = ONNX_DIR) -> None:
    source = onnx_dir / f"zipdepth_base_{size}.onnx"
    prefix = MODEL_DIR / f"zipdepth-base-{size}-vulkan"
    if not source.is_file():
        raise SystemExit(
            f"Missing {source}; first run convert_zipdepth.py --shape {size}x{size}"
        )
    scratch = ROOT / "tools" / "model_tester" / "output" / f"pnnx-{size}"
    print(f"Converting ZipDepth-{size} for ncnn Vulkan...")
    run_pnnx(pnnx, source, prefix, scratch, force)


def export_midas(size: int, repo: Path, weights: Path, target: Path) -> None:
    import torch
    import torch.nn as nn

    # Some environments have a CPU-only/mismatched TorchVision build. MiDaS
    # does not use NMS, but TorchVision registers its fake implementation at
    # import time and expects the operator to exist.
    try:
        library = torch.library.Library("torchvision", "DEF")
        library.define("nms(Tensor boxes, Tensor scores, float iou_threshold) -> Tensor")
    except RuntimeError:
        library = None

    core = torch.hub.load(str(repo), "MiDaS_small", source="local", pretrained=False)
    core.load_state_dict(torch.load(weights, map_location="cpu"))

    class Wrapper(nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model
            self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
            self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

        def forward(self, rgb):
            return self.model((rgb - self.mean) / self.std).unsqueeze(1)

    wrapper = Wrapper(core).eval()
    example = torch.rand(1, 3, size, size)
    # Warm up first: EfficientNet-Lite replaces dynamic same-padding modules
    # with fixed-size variants during its first execution.
    with torch.no_grad():
        expected = wrapper(example)
    traced = torch.jit.trace(wrapper, example, strict=False, check_trace=False)
    with torch.no_grad():
        torch.testing.assert_close(traced(example), expected, rtol=1e-5, atol=1e-5)
    torch.jit.save(traced, target)


def convert_midas(pnnx: str, size: int, repo: Path, weights: Path, force: bool) -> None:
    prefix = MODEL_DIR / f"midas-v21-small-{size}-vulkan"
    if not force and Path(f"{prefix}.ncnn.param").is_file() and Path(f"{prefix}.ncnn.bin").is_file():
        print(f"Already converted: {prefix}")
        return
    scratch = ROOT / "tools" / "model_tester" / "output" / f"pnnx-midas-{size}"
    source = scratch / f"midas-v21-small-{size}.pt"
    if force or not source.is_file():
        if not (repo / "hubconf.py").is_file() or not weights.is_file():
            raise SystemExit(f"Missing MiDaS source/weights: {repo} / {weights}")
        scratch.mkdir(parents=True, exist_ok=True)
        print(f"Exporting MiDaS-{size} TorchScript...")
        export_midas(size, repo, weights, source)
    print(f"Converting MiDaS-{size} for ncnn Vulkan...")
    run_pnnx(pnnx, source, prefix, scratch, force)


def convert_depth_anything(pnnx: str, source: Path, force: bool) -> None:
    prefix = MODEL_DIR / "depth-anything-v2-252-vulkan"
    scratch = ROOT / "tools" / "model_tester" / "output" / "pnnx-depth-anything-252"
    print("Converting Depth Anything V2-252 for ncnn Vulkan...")
    run_pnnx(pnnx, source, prefix, scratch, force)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pnnx", default=os.environ.get("PNNX") or shutil.which("pnnx"))
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--zipdepth-onnx-dir", type=Path, default=ONNX_DIR)
    parser.add_argument("--midas-repo", type=Path,
                        default=Path.home() / ".cache/torch/hub/intel-isl_MiDaS_master")
    parser.add_argument("--midas-weights", type=Path,
                        default=Path.home() / ".cache/torch/hub/checkpoints/midas_v21_small_256.pt")
    parser.add_argument("--depth-anything-onnx", type=Path,
                        default=ROOT / "tools/depth_anything_v2.onnx")
    args = parser.parse_args()
    if not args.pnnx:
        raise SystemExit("pnnx not found; install it or pass --pnnx /path/to/pnnx")
    MODEL_DIR.mkdir(exist_ok=True)
    for size in (384, 256):
        convert(args.pnnx, size, args.force, args.zipdepth_onnx_dir)
    for size in (256, 192):
        convert_midas(args.pnnx, size, args.midas_repo, args.midas_weights, args.force)
    convert_depth_anything(args.pnnx, args.depth_anything_onnx, args.force)
    print("Linux ncnn Vulkan depth models are ready in models/.")


if __name__ == "__main__":
    main()
