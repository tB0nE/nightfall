# Meteor depth GPU selection — 2026-10-25

The development PC now uses an RX480 for its desktop and an RTX3090 for games.
Depth inference has its own GPU preference, independent of game rendering,
desktop capture, video encoding and PCVR compositor selection.

## Updated integration — 2026-10-26

The separate GPU/model/inference controls are replaced by one grouped GPU/model
picker on Linux and Windows. Each entry selects model, GPU and CPU/GPU mode with
one state update and one reload. Vulkan VDA 518×294 and Performance 392×224 are
supported alongside EdgePad when the optional runner/models and device capabilities
are available. The picker has one section per GPU plus CPU, with Vulkan and
TensorRT models together under NVIDIA. TensorRT retains its default CUDA device
behavior. New model exports carry SHA-256
manifests. Windows and untested GPU families still need runtime validation.

The original implementation notes below describe the preceding UI, not the new
combined picker. See `meteor/README.md` for the current layout and build steps.

## Original behavior

- The host tray offers Depth GPU: Auto or a detected hardware Vulkan GPU.
- Every ncnn EdgePad model uses the selected GPU. Software Vulkan CPU devices
  are excluded. Auto prefers NVIDIA when available, otherwise ncnn's default.
- Selection persists by device name in `state.toml`, surviving enumeration
  reorder. Identical-name cards are not individually distinguishable yet.
- Explicitly missing GPUs fail visibly, without silent substitution.
- GPU switching queues a generation-bound background model reload, clears
  previous output when changing the inference GPU, and preserves the stream.
- Ready status reports the GPU actually loaded.
- VDA remains CUDA/TensorRT on NVIDIA. Its GPU selector is disabled and the
  EdgePad preference is retained. CPU inference also disables GPU selection.
- Linux and Windows tray implementations expose the setting. Linux was built
  and tested; Windows UI/runtime validation remains outstanding.

The temporary NVIDIA-only Vulkan driver environment override used for this
development host must be removed when launching the updated app so AMD remains
visible. This does not change the separately running NVIDIA-only PCVR listener.

## Hardware validation

An ignored, opt-in Rust test `selected_gpu_inference_smoke` loads EdgePad 512x288
explicitly on each visible hardware GPU, checks finite nonconstant outputs and
compares them across devices. Optimized release test results on this host:

| GPU | Mean inference time, 10 warm iterations |
| --- | --- |
| RX480 (RADV POLARIS10) | 10.80 ms |
| RTX3090 | 2.23 ms |

The normalized mean output difference was 0.000951, or 0.0951% of the reference
depth range. Input was a synthetic RGB gradient; these are isolated inference
measurements, not real-content or end-to-end stream performance guarantees.

NVDEC and existing CUDA preparation/refinement stay on NVIDIA. AMD inference
therefore involves host staging and cross-device movement; choosing AMD does
not yet make the complete Meteor depth pipeline independent of NVIDIA. The
remaining acceptance test is tray selection during an active headset stream,
including returning to VDA and restarting with a saved AMD preference.
