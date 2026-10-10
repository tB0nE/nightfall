# Meteor's models

Only Meteor reads these formats; the Quest runs TFLite. Models live in
`~/.local/share/nightfall-meteor/models` (`models_dir` in meteor.toml), not
in git.

## EdgePad on ncnn

`convert_ncnn.py` turns an EdgePad ONNX model (built by
`../tools/make_host_model.py` from the ZipDepth export) into
`<name>.ncnn.param` and `<name>.ncnn.bin`, which Meteor runs on Vulkan
(`../src/ncnn.rs`):

```sh
pip install pnnx
M=~/.local/share/nightfall-meteor/models
python convert_ncnn.py $M/zipdepth_wide_512x288.onnx $M/zipdepth_wide_672x384.onnx
```

The script:
- keeps the weights fp32 (23.4 MiB); Meteor runs them with fp16 storage
  and fp32 arithmetic;
- rewrites ONNX `DepthToSpace`, which pnnx can't map, as ncnn's
  `PixelShuffle` with the same block size and mode;
- records the input size on the `Input` layer, where Meteor reads it.

The converted files aren't committed; they change whenever the model is
retrained, and the AppImage build runs the conversion.

Check a retrained model against ONNX Runtime before shipping it.
`cargo test --release -- --ignored edgepad` compares EdgePad 512 with ONNX
Runtime CUDA fp32 on 30 frames of a game capture. It needs the frames and
references as raw floats (`input.f32`, `cuda32.f32`, `trt16.f32`) in the
folder named by `EDGEPAD_TEST_DATA`. The test passes when ncnn is about as
close to fp32 as TensorRT fp16 on the same frames. On 2026-10-07:
- the first frame set: ncnn 0.061% of the depth range on average and 0.72%
  at worst, TensorRT 0.068% and 0.85%;
- a regenerated set (every 80th frame of a 100 MB capture,
  `ffmpeg ... scale=512:288:flags=area`): ncnn 0.118% and 1.04%, TensorRT
  0.137% and 1.27%.

## Video Depth Anything on shared weights

The model researcher's VDA export (`nightfall-temporal-zipdepth`,
`experiments/video_depth_anything_small/export_streaming_onnx.py`) writes
two self-contained graphs: the recurrent step (126 MB) and the cold start
for the first frame (113 MB). The cold start's weights are all in the step
too. `share_vda_weights.py` stores them once, as ONNX external data that
both graphs point at:

```sh
pip install onnx
A=.../experiments/video_depth_anything_small/artifacts/tensorrt_518x294
python share_vda_weights.py $A/vda_s_streaming_step_518x294.onnx \
    $A/vda_s_cold_start_518x294.onnx --out ~/.local/share/nightfall-meteor/models
```

| File | Size | Holds |
| --- | --- | --- |
| `vda_s_518x294.onnx.data` | 115.9 MB | Every weight of 1 KiB or more, once |
| `vda_s_518x294_step.onnx` | 10.4 MB | The step graph (mostly its temporal position constants) |
| `vda_s_518x294_cold.onnx` | 0.3 MB | The cold-start graph |

The nodes and values are unchanged (checked weight by weight on
2026-10-08), and the script writes the same bytes on every run. These three
files are what the VDA download fetches, and their SHA-256s are pinned in
`../src/vda.rs`. Re-export or retrain, and the release and the hashes need
updating together.
