#!/usr/bin/env python3
"""Replay every entry from depth_hardware_benchmark's results.json sequentially.

Each run has isolated settings, no rate cap and alignment/cleanup enabled.
Requires the same installed model/runtimes as the production benchmark.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--models', type=Path, required=True)
    parser.add_argument('--tensorrt-dir', type=Path, required=True)
    parser.add_argument('--retry-failed', action='store_true')
    args = parser.parse_args()
    previous = {}
    if args.retry_failed and (args.directory / 'replays.json').exists():
        previous = {(r['device'], r['model']): r for r in json.loads((args.directory / 'replays.json').read_text())}
    results = []
    for row in json.loads((args.directory / 'results.json').read_text()):
        device, model = row['device'], row['model']
        prior = previous.get((device, model))
        if prior and prior['returncode'] == 0 and 'stages' in prior:
            print('REPLAY ALREADY PASSED', device, model, flush=True)
            results.append(prior)
            continue
        cpu = device == 'CPU'
        amd = 'AMD' in device
        trt = device == 'NVIDIA TensorRT'
        name = ('cpu' if cpu else 'amd' if amd else 'tensorrt' if trt else 'nvidia') + '-' + model
        output = args.directory / 'replays' / (name + '.log')
        cmd = [sys.executable, str(ROOT / 'meteor/tools/test_portable_pipeline.py'),
               str(args.directory / 'game.h264'), '--models', str(args.models),
               '--ncnn', str(ROOT / 'meteor/target/ncnn/lib/libncnn.so.1'),
               '--model', model, '--rate', '0', '--output', str(output),
               '--backend', 'software' if cpu else 'vaapi' if amd else 'nvdec']
        if cpu:
            cmd += ['--cpu-inference', '--cpu-processing', '--forbid-cuda']
        elif amd:
            cmd += ['--gpu', device, '--forbid-cuda']
        elif trt:
            cmd += ['--tensorrt-dir', str(args.tensorrt_dir)]
        else:
            cmd += ['--gpu', device]
        print('REPLAY START', device, model, flush=True)
        run = subprocess.run(cmd, capture_output=True, text=True)
        text = output.read_text() if output.exists() else ''
        result = dict(device=device, model=model, log=str(output), returncode=run.returncode)
        result['cuda_loaded'] = 'CUDA loaded: True' in run.stdout
        for label, pattern, keys in [
            ('latency', r'Replay done: (\d+) frames in, (\d+) maps out, (\d+) skipped;.*?median ([\d.]+) ms, p95 ([\d.]+) ms, max ([\d.]+) ms',
             ['frames', 'maps', 'skipped', 'median_ms', 'p95_ms', 'max_ms']),
            ('stages', r'Stage medians: decode ([\d.]+) ms, handoff ([\d.]+) ms, model ([\d.]+) ms, post-processing ([\d.]+) ms',
             ['decode_ms', 'handoff_ms', 'model_ms', 'post_ms']),
        ]:
            match = re.search(pattern, text)
            if match:
                result[label] = {key: float(value) for key, value in zip(keys, match.groups())}
        result['loaded'] = re.findall(r'Replay using (.*)', text)
        if run.returncode:
            result['error'] = run.stdout + run.stderr
        results.append(result)
        (args.directory / 'replays.json').write_text(json.dumps(results, indent=2))
        print(json.dumps(result), flush=True)
    (args.directory / 'replays.json').write_text(json.dumps(results, indent=2))
    if any(row['returncode'] or 'stages' not in row for row in results):
        raise SystemExit('Some replays failed; inspect replays.json')


if __name__ == '__main__':
    main()
