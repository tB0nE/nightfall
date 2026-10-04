#!/usr/bin/env python3
"""Phase 0 benchmark: ZipDepth ONNX latency on the host GPU.

Measures batch-1 latency with ONNX Runtime's CUDA and TensorRT (fp16)
execution providers, plus the GPU memory the process uses.

Setup (once; the venv lives in meteor/target, which git ignores):
    uv venv -p 3.12 meteor/target/bench-venv
    VIRTUAL_ENV=meteor/target/bench-venv uv pip install "onnxruntime-gpu[cuda,cudnn]" tensorrt-cu13 numpy

Run from the repo root:
    meteor/target/bench-venv/bin/python meteor/tools/bench_depth.py [model.onnx ...]
"""

import argparse
import os
import statistics
import subprocess
import time

import numpy as np
import onnxruntime as ort

DEFAULT_MODELS = [
    "tools/ZipDepth/onnx_export/zipdepth_base_672x384.onnx",
    "tools/ZipDepth/onnx_export/zipdepth_base_512x288.onnx",
    "tools/ZipDepth/onnx_export/zipdepth_base_384.onnx",
]
TRT_CACHE = "meteor/target/trt-cache"


def gpu_memory_mib() -> int:
    """GPU memory used by this process, from nvidia-smi."""
    out = subprocess.run(
        ["nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader,nounits"],
        capture_output=True, text=True, check=False,
    ).stdout
    for line in out.splitlines():
        pid, used = (part.strip() for part in line.split(","))
        if int(pid) == os.getpid():
            return int(used)
    return 0


def providers(name: str):
    if name == "cuda":
        return [("CUDAExecutionProvider", {"cudnn_conv_algo_search": "EXHAUSTIVE"})]
    if name == "trt-fp16":
        os.makedirs(TRT_CACHE, exist_ok=True)
        return [
            ("TensorrtExecutionProvider", {
                "trt_fp16_enable": True,
                "trt_engine_cache_enable": True,
                "trt_engine_cache_path": TRT_CACHE,
            }),
            "CUDAExecutionProvider",
        ]
    raise ValueError(name)


def bench(model: str, provider: str, iterations: int) -> dict:
    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    options.log_severity_level = 3
    start = time.perf_counter()
    session = ort.InferenceSession(model, options, providers=providers(provider))
    load_s = time.perf_counter() - start
    used = session.get_providers()[0]
    inp = session.get_inputs()[0]
    shape = [d if isinstance(d, int) else 1 for d in inp.shape]
    image = np.random.rand(*shape).astype(np.float32)

    # Host-to-device copy included: Meteor's first version hands ONNX
    # Runtime a CPU frame from the decoder.
    for _ in range(20):
        session.run(None, {inp.name: image})
    times = []
    for _ in range(iterations):
        t = time.perf_counter()
        session.run(None, {inp.name: image})
        times.append((time.perf_counter() - t) * 1000)
    times.sort()
    return {
        "provider": used,
        "load_s": load_s,
        "median_ms": statistics.median(times),
        "p95_ms": times[int(len(times) * 0.95) - 1],
        "mem_mib": gpu_memory_mib(),
        "size": f"{shape[3]}x{shape[2]}",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("models", nargs="*", default=DEFAULT_MODELS)
    parser.add_argument("--providers", default="cuda,trt-fp16")
    parser.add_argument("--iterations", type=int, default=300)
    args = parser.parse_args()

    # Load the CUDA, cuDNN and TensorRT libraries installed by pip.
    if hasattr(ort, "preload_dlls"):
        ort.preload_dlls()
    print(f"onnxruntime {ort.__version__}, available: {', '.join(ort.get_available_providers())}")
    print(f"{'model':<34} {'requested':<9} {'ran on':<26} {'load s':>7} {'median ms':>9} {'p95 ms':>7} {'max Hz':>7} {'GPU MiB':>8}")
    for model in args.models:
        for provider in args.providers.split(","):
            try:
                r = bench(model, provider, args.iterations)
            except Exception as err:  # noqa: BLE001 - report and keep going
                print(f"{os.path.basename(model):<34} {provider:<9} failed: {err}")
                continue
            print(
                f"{os.path.basename(model):<34} {provider:<9} {r['provider']:<26} {r['load_s']:>7.1f} "
                f"{r['median_ms']:>9.2f} {r['p95_ms']:>7.2f} {1000 / r['p95_ms']:>7.0f} {r['mem_mib']:>8}"
            )


if __name__ == "__main__":
    main()
