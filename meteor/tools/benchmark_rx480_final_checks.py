#!/usr/bin/env python3
"""Bounded, standalone RX480 VDA experiments; never changes Meteor settings.

Requires the existing original-resolution video fixtures and repaired models.
Run with --root .build-cache/vda-vulkan-spike --tag UNIQUE_NAME.
Checks saved depth and all eight temporal states against the validated baseline.
Nonidentical output requires independent CPU-reference validation before adoption.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    if not args.tag or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-_' for c in args.tag):
        parser.error('tag must contain only lowercase letters, numbers, hyphen or underscore')
    root = args.root
    sequence = root / 'video-sequence-01'
    reference = sequence / 'rx480-518-no-local'
    outputs = sorted(reference.glob('*.f32')) + sorted(reference.glob('*.f16'))
    if len(outputs) != 720:
        parser.error('expected the validated 80-frame / nine-output reference')
    base = {k: v for k, v in os.environ.items()
            if not k.startswith(('VDA_PROBE_', 'VDA_PROFILE_'))}
    base.update(
        VK_ICD_FILENAMES='/usr/share/vulkan/icd.d/radeon_icd.x86_64.json',
        VDA_PROBE_SEQUENCE='1', VDA_PROBE_COLD_PREFIX=str(root / 'cold-repaired'),
        VDA_PROBE_RESIDENT='1', VDA_PROBE_PACKING='1',
        VDA_PROBE_FP16_STORAGE='1', VDA_PROBE_NO_COOPERATIVE_MATRIX='1',
        VDA_PROBE_FUSED_LAYERNORM='1', VDA_PROBE_SPATIAL_KEY_PAD='1',
        VDA_PROBE_SPATIAL_QUERIES='12', VDA_PROBE_SPATIAL_SUBGROUP='1',
        VDA_PROBE_SPATIAL_PACKED64='1', VDA_PROBE_NO_LOCAL_MEMORY='1')
    cases = [
        ('control-before', {}),
        ('fixed-gemm', {'VDA_PROBE_PORTABLE_GEMM': '1',
                        'VDA_PROBE_PORTABLE_GEMM_FIXED_SHAPE': '1'}),
        ('unpacked-layout', {'VDA_PROBE_PACKING': None}),
        ('shuffle-attention', {'VDA_PROBE_SPATIAL_SHUFFLE_SCORES': '1'}),
        ('control-after', {}),
    ]
    destinations = [sequence / f'{args.tag}-{name}' for name, _ in cases]
    if any(p.exists() or Path(str(p) + '.log').exists() for p in destinations):
        parser.error('use a fresh tag; existing results will not be overwritten')
    reports = []
    for (name, overrides), output in zip(cases, destinations):
        env = base | {k: v for k, v in overrides.items() if v is not None}
        for key, value in overrides.items():
            if value is None:
                env.pop(key, None)
        with Path(str(output) + '.log').open('w') as log:
            result = subprocess.run([
                str(root / 'probe-final-checks'), str(root / 'step-amd-scalar-spatial'),
                '0', str(sequence), str(output)], env=env, stdout=log, stderr=log)
        report = {'case': name, 'returncode': result.returncode, 'overrides': overrides}
        if result.returncode == 0:
            with (output / 'timings.csv').open() as file:
                rows = [r for r in csv.DictReader(file)
                        if r['reset'] == 'none' and int(r['frame']) >= 8]
            values = sorted(float(r['graph_ms']) for r in rows)
            report.update(samples=len(values), median_ms=statistics.median(values),
                          p95_ms=values[int(.95 * len(values))])
            files = list(output.glob('*.f32')) + list(output.glob('*.f16'))
            report['output_count'] = len(files)
            report['identical_outputs'] = sum(
                (output / f.name).is_file() and (output / f.name).read_bytes() == f.read_bytes()
                for f in outputs)
            report['history_match'] = (output / 'history.tsv').read_bytes() == (
                reference / 'history.tsv').read_bytes()
        reports.append(report)
        (root / f'{args.tag}-summary.json').write_text(json.dumps(reports, indent=2) + '\n')
        print(json.dumps(report), flush=True)
    return 0 if all(r['returncode'] == 0 and r.get('output_count') == 720
                    and r.get('history_match') for r in reports) else 1


if __name__ == '__main__':
    raise SystemExit(main())
