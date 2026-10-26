#!/usr/bin/env python3
"""Export the unchanged VDA-S checkpoint at an explicit fixed resolution.

Reads the existing research checkout; writes only to --output. CUDA is used for
export, not as a runtime requirement for the resulting ONNX/ncnn models.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-dir', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--width', type=int, required=True)
    parser.add_argument('--height', type=int, required=True)
    args = parser.parse_args()
    if min(args.width, args.height) < 14 or args.width % 14 or args.height % 14:
        parser.error('Dimensions must be positive multiples of the 14-pixel patch size')
    args.output.mkdir(parents=True, exist_ok=True)
    if any((args.output / f'{name}.onnx').exists() for name in ('cold', 'step')):
        parser.error('Choose a fresh output directory')
    sys.path.insert(0, str(args.source_dir.resolve()))
    sys.dont_write_bytecode = True
    import torch
    from export_streaming_onnx import (StreamingStep, ColdStartStep,
        use_exportable_dino_attention, use_exact_single_frame_temporal_attention)
    from run_vda_benchmark import load_model, CHECKPOINT
    torch.set_num_threads(4)
    torch.manual_seed(11)
    use_exportable_dino_attention()
    model = load_model(streaming=True).eval()
    image = torch.randn(1, 1, 3, args.height, args.width, device='cuda')
    with torch.inference_mode():
        features = model.forward_features(image)
        _, current = model.forward_depth(features, image.shape)
        cache = tuple(value.repeat(1, 31, 1).contiguous() for value in current)
        wrapper = StreamingStep(model).eval()
        result = wrapper(image, *cache)
        if len(result) != 9 or not all(torch.isfinite(value).all() for value in result):
            raise ValueError('Invalid streaming outputs')
        torch.onnx.export(wrapper, (image, *cache), str(args.output/'step.onnx'),
            input_names=['image']+[f'cache_{i}' for i in range(8)],
            output_names=['depth']+[f'updated_cache_{i}' for i in range(8)],
            opset_version=18, dynamo=False, do_constant_folding=True)
        contract = {'width': args.width, 'height': args.height,
            'inputs': [list(image.shape)]+[list(value.shape) for value in cache],
            'outputs': [list(value.shape) for value in result], 'history_samples': 31,
            'checkpoint_sha256': hashlib.sha256(CHECKPOINT.read_bytes()).hexdigest(),
            'checkpoint': str(CHECKPOINT), 'weights_changed': False}
        print('Streaming export complete', flush=True)
        use_exact_single_frame_temporal_attention()
        cold = ColdStartStep(model).eval()
        outputs = cold(image)
        if not all(torch.isfinite(value).all() for value in outputs):
            raise ValueError('Invalid cold outputs')
        torch.onnx.export(cold, (image,), str(args.output/'cold.onnx'),
            input_names=['image'], output_names=['depth']+[f'updated_cache_{i}' for i in range(8)],
            opset_version=18, dynamo=False, do_constant_folding=True)
    (args.output/'contract.json').write_text(json.dumps(contract, indent=2)+'\n')
    print(json.dumps(contract), flush=True)


if __name__ == '__main__':
    main()
