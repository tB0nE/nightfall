# Meteor's models

Only Meteor reads these formats; the Quest runs TFLite. Models live in
`~/.local/share/nightfall-meteor/models` (`models_dir` in meteor.toml), not
in git.

## EdgePad on ncnn

For the lower-compute EdgePad-256 option, from the repository root:

```sh
python meteor/tools/make_host_model.py \
  tools/ZipDepth/onnx_export/zipdepth_base_256_standard_packed_conv4_reduceconv_edgepad.onnx \
  ~/.local/share/nightfall-meteor/models/zipdepth_edgepad_256.onnx \
  models/zipdepth-base-256-standard-packed-conv4-reduceconv-edgepad-gpu.tflite
python meteor/models/convert_ncnn.py ~/.local/share/nightfall-meteor/models/zipdepth_edgepad_256.onnx
```

Both Linux and Windows release packaging require the 256 and 512 ncnn
models. The 256 option is manual and does not change the default.

Local smoke test (RTX 3090, 2026-10-12, desktop `eg_input_1.png`, 20
back-to-back Vulkan calls including input upload/output download):

| Model | Vulkan median | CPU median, four threads |
| --- | --- | --- |
| EdgePad-256 | 1.96 ms | 15.94 ms |
| EdgePad-384 | 2.52 ms | 33.92 ms |
| EdgePad-512x288 | 2.68 ms | 31.88 ms |

These are short inference-only measurements, not live streaming latency
or predictions for weaker GPUs. Vulkan FP16 storage differs from ONNX
CPU FP32 by 0.274%, 0.133% and 0.092% of depth range on average,
respectively, on this image. A synthetic smooth gradient was more
sensitive (256: 1.36% mean, 4.94% worst), so this is not lossless and
does not replace a varied-image quality check. CPU ncnn matches ONNX
CPU to within 0.0011% worst in these smoke tests.

`cargo test --release edgepad_cpu_parity -- --ignored --nocapture` checks
the installed models. `EDGEPAD_TEST_GPU=1` adds Vulkan checks, and
`EDGEPAD_TEST_RGB=<folder>` reads interleaved RGB24 files named
`256x256.rgb`, `384x384.rgb`, `512x288.rgb` instead of the gradient.

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


## Published Vulkan VDA downloads

VDA Small 518×294 and 392×224 ncnn exports are optional downloads in Meteor's
GPU / model menu, from the existing `meteor-vda-s-518x294` model release.
`vda-vulkan-downloads.json` pins every asset's public name, byte count and SHA-256.
Both variants retain the same original checkpoint; neither is newly trained.
They use the bundled portable Vulkan runtime, without TensorRT/CUDA downloads.

Each installed directory has cold/step `.ncnn.param` and `.ncnn.bin`, a runtime
manifest and the Apache 2.0 license. Installation is staged outside the visible
model list, resumed as needed and published only after verification. Downloading
does not select a different inference model or GPU. Keep the existing
`stage_vda_vulkan_models.py` exports as the model-release inputs; do not regenerate
weights simply to make a release. A public integration test is available in
`test/check_meteor_vda_downloads.py`.
