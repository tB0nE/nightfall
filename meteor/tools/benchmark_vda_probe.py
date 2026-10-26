#!/usr/bin/env python3
"""Run the standalone VDA probe and optionally sample NVIDIA clocks/load.

Example: benchmark_vda_probe.py --output PREFIX --nvidia-stats -- PROBE ARGS...
Model correctness must be validated separately; timings alone are not acceptance.
"""
import argparse
import csv
import json
from pathlib import Path
import re
import statistics
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--nvidia-stats", action="store_true")
    parser.add_argument("--warmup", type=int, default=50)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or args.warmup < 0:
        parser.error("a probe command and nonnegative warmup are required")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    log_path = Path(str(args.output) + ".log")
    stats = []
    started = time.monotonic()
    with log_path.open("w") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                if args.nvidia_stats:
                    fields = "pstate,clocks.gr,clocks.mem,power.draw,utilization.gpu,memory.used"
                    result = subprocess.run(["nvidia-smi", "--query-gpu=" + fields,
                                             "--format=csv,noheader,nounits"],
                                            capture_output=True, text=True, timeout=5)
                    if result.returncode == 0:
                        for row in csv.reader(result.stdout.splitlines()):
                            stats.append([round(time.monotonic()-started, 3)] + [x.strip() for x in row])
                time.sleep(0.25)
        except BaseException:
            process.terminate()
            process.wait()
            raise
    with Path(str(args.output) + ".clocks.csv").open("w") as output:
        writer = csv.writer(output)
        writer.writerow(["elapsed_s", "pstate", "graphics_mhz", "memory_mhz", "power_w", "gpu_percent", "memory_mib"])
        writer.writerows(stats)
    values = [float(x) for x in re.findall(r"resident_graph_ms=([\d.]+)", log_path.read_text())]
    measured = values[args.warmup:]
    report = {"returncode": process.returncode, "samples": len(values),
              "warmup_excluded": args.warmup, "clock_samples": len(stats)}
    if measured:
        ordered = sorted(measured)
        report.update(median_ms=statistics.median(measured),
                      p95_ms=ordered[min(len(ordered)-1, int(len(ordered)*0.95))])
    Path(str(args.output) + ".summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return process.returncode or (0 if measured else 1)


if __name__ == "__main__":
    raise SystemExit(main())
