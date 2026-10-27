# Meteor Vulkan frame processing — 2026-10-26

Branch: `feat/meteor-xr-streaming`. This follows the hardware comparison in
`tools/model_tester/output/meteor-hardware-comparison-20261026/README.md`.
The measured GPU inference was fast enough to expose large CPU costs around it.

## Implemented

- The optional ncnn-based native runtime now exports a separate, versioned image
  processing ABI. Models, checkpoints, resolutions and quality controls are unchanged.
- VAAPI/software decode still transfers NV12 to host memory. Its existing 4×4
  footprint average, H.273 matrix conversion, range handling and RGB quantization
  can now execute on the selected Vulkan GPU. The decoder returns the same RGB24
  layout to the worker. CPU fallback is logged and remains available.
- Vulkan VDA performs bicubic resizing/DINO normalization on GPU. Its prepared
  tensor remains on GPU through the graph, and its thumbnail reduction downloads
  only 432 floats for the existing scene-cut decision. Both RGB24 and planar input
  are supported. GPU depth softening uses the same separable Gaussian as the CPU.
- A preparation failure falls back to the CPU reference until model reload, with
  a warning. The advanced CPU-frame-processing option explicitly selects the CPU
  preparation/softening path too; VDA model inference still requires a GPU.
- For portable RGB frames, final percentile range estimation, temporal smoothing,
  quantization, bounded alignment and contour cleanup run on Vulkan. Temporal
  state is separate from the model history, so refinement never feeds the model.
  Packed 8-bit finished maps are read back. Existing NVIDIA CUDA processing of
  NVDEC frames remains in use.
- Optional postprocessing failure resets CPU smoothing and uses the CPU reference
  until the next model/stream change. Processing buffers and pipelines are reused;
  processors reset on stream/model/GPU changes and release buffers before allocators.
- Portable VDA GPU preparation is skipped while inference is busy. Packets continue
  to decode without requesting pixels; the next fresh frame can be prepared after
  inference. This avoids queueing expensive filtering behind the preceding model
  on the same GPU. The busy marker has scoped cleanup even on an inference error.
  Short EdgePad models keep pipelined preparation: gating those jobs needlessly
  reduced uncapped update throughput. Portable pixel conversion is also skipped
  when there are no depth subscribers or snapshot requests.
- Native runtime version and dimensions are checked. Image-processing FP32 buffers
  are independent of model FP16 buffers. GPU allocation and operation failures are
  checked rather than dereferencing absent outputs.

## Validation

Hardware: Linux, RX 480/RADV and RTX 3090; ncnn 20260526, release builds.

- NV12: four source/target geometries including 1280×720 output, BT.709/601/2020,
  limited/full range, both GPUs. Maximum RGB difference was one 8-bit level.
- Bicubic normalization: both VDA sizes, RGB24 and planar input, both GPUs. Maximum
  absolute difference from the CPU reference was about 0.0000022.
- Softening: both VDA sizes, Off/Light/Medium/High, both GPUs. Maximum absolute
  difference from CPU was about 0.000002.
- Final processing: flat, spatially varying, temporal smoothing on/off, guide-size
  changes, alignment/cleanup combinations, non-multiple-of-four output counts,
  reset, invalid input. Final cleanup differed by at most two 8-bit levels on AMD
  and one on NVIDIA in these fixtures; mean difference was below 0.00022 levels.
- Complete VDA comparison: 80 frames per size per GPU, RGB/planar input, scene cuts,
  timestamp gap and history rollover. Worst per-frame mean difference was 0.0251%
  of depth range, worst individual pixel 1.449%. This is numerically close, not a
  claim of bitwise identity. Slight preprocessing/half-rounding differences can
  be amplified through learned inference.
- Replay tooling now explicitly enables info logging and isolates the log folder.
  The forked GUI environment sets `RUST_LOG=warn`, which initially suppressed
  timing summaries; affected runs are repeated rather than accepted without data.

Release regression results and final before/after replay measurements are recorded
in the companion report under `tools/model_tester/output/meteor-vulkan-pipeline-20261026/`.

### RX 480 complete-pipeline result

Same 360-frame H.264 game clip, uncapped inference, alignment and cleanup enabled.
Median compressed-frame-to-finished-map latency; networking/display excluded.

| Model | Before | After |
|---|---:|---:|
| EdgePad-256 | 49.2 ms | 14.3 ms |
| EdgePad-384 | 65.0 ms | 20.2 ms |
| EdgePad-512 | 54.2 ms | 20.3 ms |
| EdgePad-672 | 74.6 ms | 41.1 ms |
| VDA Full | 299.9 ms | 97.5 ms |
| VDA Performance | 347.5 ms | 64.8 ms |

132 release regression tests passed; 16 opt-in tests remain ignored by the normal
suite. The new processing/parity hardware tests and all 17 replay combinations
were exercised separately. NVIDIA TensorRT remained about 5.1 ms. A same-window
EdgePad-512 control measured 7.5 ms for the saved older executable versus 7.2 ms
for the new one; historical NVIDIA timings varied more than that controlled pair.
The final release also preserves the `--cpu-post` and `--cpu-frames` comparison
overrides, validated with separate AMD replays and no CUDA loaded.

## Remaining work

Output residency is now implemented as a scoped follow-up: portable RGB EdgePad
and VDA return an owned Vulkan tensor directly to final processing. The EdgePad
bridge uses the existing ncnn net through its published C handle declaration;
it does not load duplicate models. Resident tensors retain their allocator and
native library independently of the model, and own a device-side copy so another
inference cannot overwrite them. The GPU checks raw-depth finiteness before a
map is accepted. CPU reference/fallback readback remains explicit. Processing ABI
is now version 2. Existing NVDEC/CUDA and CPU-only paths remain available.

The follow-up report is in
`tools/model_tester/output/meteor-resident-output-20261026/README.md`.
Both GPUs passed resident EdgePad parity, tensor lifetime, invalid-value recovery
and device-mismatch checks. VDA's 80-frame comparisons include resident final
processing and retaining the output after model destruction.

Further GPU optimization is deferred at the user's request. Resume the branch's
main XR streaming work after this change; the following are future possibilities:

1. Decoder interoperability: direct VAAPI/dma-buf to Vulkan image sharing,
   and an equivalent Windows path, avoiding NV12/RGB host round trips. This is not
   required for the current implementation and needs separate platform validation.
2. Cold-state initialization still uses the existing host conversion when the
   model resets. Moving that initial state conversion to GPU could reduce reset
   and scene-cut cost; ordinary temporal steps already retain history on GPU.
3. Validate newer AMD/Intel hardware and Windows. No RX 7800 XT speed or Windows
   runtime claim has been made. No model retraining is needed for these operations.
4. Live headset testing of model switches, new streams, processing toggles and
   game/desktop GPU contention. Local replay and parity checks do not replace it.

## Files and reproduction

- `meteor/native/vulkan_processing.h`: FP32 compute kernels and buffer ownership.
- `meteor/native/vda_vulkan.cpp`: native C ABI and VDA GPU preparation integration.
- `meteor/src/vulkan_processing.rs`: checked FFI, postprocessing timing/history.
- `meteor/src/vda_vulkan.rs`: scene-cut policy and CPU reference override/fallback.
- `meteor/src/video_decoder.rs`, `meteor/src/depth.rs`: production pipeline.
- Opt-in tests: `vulkan_processing::tests::`, `prepared_video_matches_reference`.
- Normal regression: `cargo test --manifest-path meteor/Cargo.toml --release --locked --no-default-features`.
- Replay: `meteor/tools/benchmark_hardware_replay.py`, same source clip and
  settings as the original comparison. Logs remain in `.build-cache/meteor-vulkan-pipeline-20261026/`.

No commits, release uploads or headset deployment are part of this change yet.
