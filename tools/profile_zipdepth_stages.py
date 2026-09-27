#!/usr/bin/env python3
"""Profile ZipDepth's Standard path and mark the Direct-192 boundary.

This is the local CUDA half of the staged profiling plan.  It times the fused,
GPU-safe graph one dependency-preserving stage at a time and also reports
end-to-end Direct and Standard latency.  These numbers identify architectural
cost; they do not replace the eventual LiteRT Adreno OpenCL benchmark.
"""

from __future__ import annotations

import argparse
import json
import statistics
import time
from pathlib import Path
from typing import Callable

import torch
import torch.nn.functional as F

from export_zipdepth_gpu_safe import (
    expand_unaligned_grouped_convolution,
    expose_half_resolution_depth,
    load_model,
    patch_export_graph,
    rewrite_standard_upsampling_head,
)


TensorFn = Callable[[], torch.Tensor | tuple[torch.Tensor, ...]]


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    position = min(int(round((len(ordered) - 1) * fraction)), len(ordered) - 1)
    return ordered[position]


def benchmark(
    function: TensorFn, warmup: int, iterations: int, device: torch.device
) -> dict[str, float]:
    for _ in range(warmup):
        function()
    if device.type == "cuda":
        torch.cuda.synchronize()

    samples = []
    if device.type == "cuda":
        start = torch.cuda.Event(enable_timing=True)
        end = torch.cuda.Event(enable_timing=True)
        for _ in range(iterations):
            start.record()
            function()
            end.record()
            end.synchronize()
            samples.append(float(start.elapsed_time(end)))
    else:
        for _ in range(iterations):
            start_time = time.perf_counter()
            function()
            samples.append((time.perf_counter() - start_time) * 1000.0)
    return {
        "median_ms": statistics.median(samples),
        "mean_ms": statistics.fmean(samples),
        "p90_ms": percentile(samples, 0.90),
        "p99_ms": percentile(samples, 0.99),
    }


def tensor_description(value: torch.Tensor | tuple[torch.Tensor, ...]) -> str:
    tensors = value if isinstance(value, tuple) else (value,)
    return ",".join("x".join(str(item) for item in tensor.shape) for tensor in tensors)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--size", type=int, default=384)
    parser.add_argument("--warmup", type=int, default=30)
    parser.add_argument("--iterations", type=int, default=200)
    parser.add_argument("--device", choices=("cuda", "cpu"), default="cuda")
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=Path(__file__).resolve().parent
        / "ZipDepth/checkpoints/zipdepth_base.pth",
    )
    parser.add_argument(
        "--output",
        type=Path,
    )
    args = parser.parse_args()

    if args.device == "cuda" and not torch.cuda.is_available():
        raise SystemExit("CUDA is required for this profiler")

    if args.device == "cuda":
        torch.backends.cudnn.benchmark = True
    else:
        torch.set_num_threads(args.threads)
    device = torch.device(args.device)
    dtype = torch.float16 if device.type == "cuda" else torch.float32

    standard = load_model(args.checkpoint, upsample_unfold=True)
    patch_export_graph(standard, args.size, args.size, gpu_safe=True)
    expand_unaligned_grouped_convolution(standard)
    rewrite_standard_upsampling_head(standard)
    standard = standard.to(device=device, dtype=dtype).eval()

    direct = load_model(args.checkpoint, upsample_unfold=True)
    patch_export_graph(direct, args.size, args.size, gpu_safe=True)
    expand_unaligned_grouped_convolution(direct)
    expose_half_resolution_depth(direct)
    direct = direct.to(device=device, dtype=dtype).eval()

    image = torch.rand(
        1, 3, args.size, args.size, device=device, dtype=dtype
    )

    with torch.inference_mode():
        normalized = (image - standard.mean) / standard.std
        encoder = standard.encoder
        decoder = standard.decoder

        s_half = encoder.stem_half(normalized)
        s_quarter = encoder.stem_quarter(s_half)
        s1 = encoder.stage1(s_quarter)
        s2_pre = encoder.down2(s1)
        s2 = encoder.stage2(s2_pre)
        s3_pre = encoder.down3(s2)
        s3_raw = encoder.stage3(s3_pre)
        s4_pre = encoder.down4(s3_raw)
        s4_raw = encoder.stage4(s4_pre)
        s4_spp = encoder.spp(s4_raw)
        s3, s4 = encoder.cross_scale(s3_raw, s4_spp)

        f4 = decoder.proj4(s4)
        f3 = decoder.fuse3(s3, f4)
        f2 = decoder.fuse2(s2, f3)
        f1 = decoder.fuse1(s1, f2)
        f_half = decoder.fuse_half(s_half, f1)
        depth_half = decoder.head_half(f_half)

        mask_logits = decoder.convex_up.mask_pred(f_half)
        batch, _, height, width = mask_logits.shape
        mask_shaped = mask_logits.view(batch, 9, 4, height, width)
        mask = F.softmax(mask_shaped / decoder.convex_up.temperature, dim=1)

        kernels = depth_half.new_zeros((9, 1, 3, 3))
        for index in range(9):
            kernels[index, 0, index // 3, index % 3] = 1.0
        depth_pad = F.pad(depth_half, (1, 1, 1, 1), mode="replicate")
        neighbors = F.conv2d(depth_pad, kernels)
        subpixels = []
        for index in range(4):
            subpixels.append(
                (mask[:, :, index, :, :] * neighbors).sum(dim=1, keepdim=True)
            )
        weighted = torch.cat(subpixels, dim=1)

        stages: list[tuple[str, TensorFn]] = [
            ("normalize", lambda: (image - standard.mean) / standard.std),
            ("encoder_stem_half", lambda: encoder.stem_half(normalized)),
            ("encoder_stem_quarter", lambda: encoder.stem_quarter(s_half)),
            ("encoder_stage1", lambda: encoder.stage1(s_quarter)),
            ("encoder_stage2", lambda: encoder.stage2(encoder.down2(s1))),
            ("encoder_stage3", lambda: encoder.stage3(encoder.down3(s2))),
            ("encoder_stage4", lambda: encoder.stage4(encoder.down4(s3_raw))),
            ("encoder_spp", lambda: encoder.spp(s4_raw)),
            ("encoder_cross_scale", lambda: encoder.cross_scale(s3_raw, s4_spp)),
            ("decoder_proj4", lambda: decoder.proj4(s4)),
            ("decoder_fuse3", lambda: decoder.fuse3(s3, f4)),
            ("decoder_fuse2", lambda: decoder.fuse2(s2, f3)),
            ("decoder_fuse1", lambda: decoder.fuse1(s1, f2)),
            ("direct_fuse_half", lambda: decoder.fuse_half(s_half, f1)),
            ("direct_head_half", lambda: decoder.head_half(f_half)),
            ("standard_mask_prediction", lambda: decoder.convex_up.mask_pred(f_half)),
            (
                "standard_mask_softmax",
                lambda: F.softmax(mask_shaped / decoder.convex_up.temperature, dim=1),
            ),
            (
                "standard_neighbour_extract",
                lambda: F.conv2d(
                    F.pad(depth_half, (1, 1, 1, 1), mode="replicate"), kernels
                ),
            ),
            (
                "standard_weighted_reduction",
                lambda: torch.cat(
                    [
                        (mask[:, :, index, :, :] * neighbors).sum(
                            dim=1, keepdim=True
                        )
                        for index in range(4)
                    ],
                    dim=1,
                ),
            ),
            ("standard_pixel_shuffle", lambda: F.relu(F.pixel_shuffle(weighted, 2))),
            ("end_to_end_direct", lambda: direct(image)),
            ("end_to_end_standard", lambda: standard(image)),
        ]

        report = {
            "created": time.strftime("%Y-%m-%d %H:%M:%S"),
            "device": (
                torch.cuda.get_device_name(0)
                if device.type == "cuda"
                else "CPU (PyTorch eager)"
            ),
            "torch": torch.__version__,
            "input": [1, 3, args.size, args.size],
            "dtype": str(dtype),
            "warmup": args.warmup,
            "iterations": args.iterations,
            "note": (
                "Local CUDA architectural profile; not predictive of LiteRT "
                "Adreno OpenCL latency."
            ),
            "stages": {},
        }
        print(f"Device: {report['device']} ({dtype})")
        print(f"{'stage':<34} {'shape':<28} {'median':>9} {'p90':>9} {'p99':>9}")
        print("-" * 94)
        for name, function in stages:
            output = function()
            result = benchmark(
                function, args.warmup, args.iterations, device
            )
            result["output_shape"] = tensor_description(output)
            report["stages"][name] = result
            print(
                f"{name:<34} {result['output_shape']:<28} "
                f"{result['median_ms']:>8.4f} "
                f"{result['p90_ms']:>8.4f} {result['p99_ms']:>8.4f}"
            )

    output = args.output or (
        Path(__file__).resolve().parent
        / f"model_tester/output/zipdepth-stage-profile-{args.device}.json"
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"\nWrote {output}")


if __name__ == "__main__":
    main()
