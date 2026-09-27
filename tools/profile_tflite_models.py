#!/usr/bin/env python3
"""Repeatable local XNNPACK benchmark for one or more TFLite models."""

from __future__ import annotations

import argparse
import json
import statistics
import time
from collections import Counter
from pathlib import Path

import numpy as np
from ai_edge_litert.interpreter import Interpreter


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[min(round((len(ordered) - 1) * fraction), len(ordered) - 1)]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("models", type=Path, nargs="+")
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--warmup", type=int, default=20)
    parser.add_argument("--iterations", type=int, default=100)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    rng = np.random.default_rng(7)
    report = {
        "created": time.strftime("%Y-%m-%d %H:%M:%S"),
        "backend": "LiteRT XNNPACK CPU",
        "threads": args.threads,
        "warmup": args.warmup,
        "iterations": args.iterations,
        "models": [],
    }

    print(f"{'model':<52} {'output':<18} {'ops':>5} {'median':>9} {'p90':>9} {'p99':>9}")
    print("-" * 110)
    for path in args.models:
        interpreter = Interpreter(model_path=str(path), num_threads=args.threads)
        interpreter.allocate_tensors()
        input_detail = interpreter.get_input_details()[0]
        output_detail = interpreter.get_output_details()[0]
        sample = rng.random(input_detail["shape"], dtype=np.float32)
        interpreter.set_tensor(input_detail["index"], sample)

        for _ in range(args.warmup):
            interpreter.invoke()
        samples = []
        for _ in range(args.iterations):
            start = time.perf_counter()
            interpreter.invoke()
            samples.append((time.perf_counter() - start) * 1000.0)

        operations = interpreter._get_ops_details()
        result = {
            "path": str(path),
            "input_shape": input_detail["shape"].tolist(),
            "output_shape": output_detail["shape"].tolist(),
            "operation_count": len(operations),
            "operations": dict(Counter(item["op_name"] for item in operations)),
            "median_ms": statistics.median(samples),
            "mean_ms": statistics.fmean(samples),
            "p90_ms": percentile(samples, 0.90),
            "p99_ms": percentile(samples, 0.99),
        }
        report["models"].append(result)
        shape = "x".join(str(item) for item in result["output_shape"])
        print(
            f"{path.name:<52} {shape:<18} {len(operations):>5} "
            f"{result['median_ms']:>8.3f} {result['p90_ms']:>8.3f} "
            f"{result['p99_ms']:>8.3f}"
        )

    output = args.output or (
        Path(__file__).resolve().parent
        / "model_tester/output/zipdepth-tflite-xnnpack-profile.json"
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"\nWrote {output}")


if __name__ == "__main__":
    main()
