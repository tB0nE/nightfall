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
