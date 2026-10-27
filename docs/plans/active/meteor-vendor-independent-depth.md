# Vendor-independent EdgePad pipeline

## Scope

Make Meteor host-depth usable without NVIDIA. Keep the current low-latency
NVDEC/CUDA path for NVIDIA, and VDA NVIDIA-only. Add explicit advanced choices
for mixed-vendor systems without changing the desktop host or PCVR encoder.

## Implementation

1. Add an in-process FFmpeg decoder adapter with exact packet/frame IDs.
   Support Linux VAAPI and software decoding; keep NVDEC as an independent
   backend. Do not use an ffmpeg subprocess or assume the newest output belongs
   to the newest packet. Validate supported FFmpeg ABI versions at runtime.
2. Download decoded VAAPI surfaces to CPU NV12, retaining crop, matrix/range and
   frame identity. Reuse the existing 4×4 footprint input filter. CPU preparation,
   smoothing and refinement remove CUDA requirements for ncnn EdgePad.
3. Persist advanced decoder Auto/NVDEC/VAAPI/Software, VAAPI device Auto or an
   available DRM render node, and processing Auto/CPU. Separate these settings
   from the existing inference GPU and CPU/GPU inference choices.
4. Apply decoder changes at a new stream/keyframe; log pending and actual paths.
   Auto tries compatible backends and reports fallback reasons. Explicit choices
   fail visibly instead of silently substituting a backend.
5. Add decoder identity/reordering/failure tests, software and RX480 VAAPI
   hardware fixtures, and an EdgePad decode → input → model → refinement check
   with the compatibility path prohibited from using CUDA.
6. Package the optional FFmpeg runtime and licenses for Linux AppImages; document
   runtime requirements and Windows limitations. Restart dev Meteor after checks.

## Acceptance

- AMD-only compatibility path works with NVDEC/CUDA unavailable.
- Existing NVIDIA defaults and VDA remain supported.
- Model/frame association is correct, including delayed decoder output.
- Saved settings and actual backend/device are visible in the tray/logs.
- Compare full pipeline latency rather than claiming VAAPI download/CPU work is
  equivalent in speed to NVDEC's CUDA tensor path.

XR headset full-sleep recovery is separate outstanding work; this task does not
claim to fix it.

## Implemented and validated

The Linux dev Meteor was rebuilt and restarted with the portable path and
advanced tray controls. Existing user model/GPU preferences were preserved.
The live tray exposes both AMD and NVIDIA render devices. No headset APK change
was needed; the existing wire protocol is unchanged.

Validation:

- Full Rust suite: 125 passed, 12 opt-in tests ignored.
- Explicit software and RX480 VAAPI decoding: H.264 and HEVC, 20 frames each,
  with B-frame reordering and source frame IDs retained. VAAPI RGB agrees with
  software within one average 8-bit level; no CUDA library loaded.
- Cached, parallel CPU footprint sampling matches the existing scalar 4×4
  reference byte-for-byte across test dimensions, ranges and color matrices.
- Complete release-build replays: 1280×720/60 fps H.264 fixture, EdgePad-256,
  requested 20 Hz, alignment and contour cleanup enabled:

| Path | Maps in 6 seconds | Median / p95 frame-to-map latency | CUDA loaded |
| --- | --- | --- | --- |
| RX480 + Auto → VAAPI + CPU processing | 120 | 21.9 / 45.0 ms | No |
| RX480 + software decode + CPU processing | 120 | 25.9 / 40.9 ms | No |
| RTX3090 + NVDEC + Auto/CUDA processing | 118 | 4.2 / 7.8 ms | Yes |

These are short, host-local synthetic replays, not headset/network latency or
game-load guarantees. Scripts and logs are under `meteor/tools/test_portable_pipeline.py`
and `.build-cache/meteor-portable-tests/`; hardware fixture coverage is the
ignored `portable_decoder_frame_identity_and_amd_surfaces` Rust test.

Two issues discovered during validation were fixed: portable preparation and
inference no longer independently rate-limit the same frames, and listing VDA
models no longer eagerly initializes TensorRT/CUDA. VDA initializes TensorRT
only when requested. Auto decoder affinity is reconsidered at a keyframe after
changing the inference GPU or choosing VDA.

## Boundaries and remaining validation

- Linux headset streaming and live decoder changes still need user testing.
- Linux AppImage scripts now build/bundle a checksum-pinned minimal FFmpeg
  8.0.1 runtime and license notices. Shell syntax was checked; a complete new
  AppImage build has not been performed in this session.
- The software adapter and controls compile as portable code, but Windows
  FFmpeg DLL packaging and Windows runtime validation remain outstanding.
- VDA and the PCVR compositor/encoder remain NVIDIA-only. Vibepollo's capture
  and encoder configuration were not changed by this work.
- A genuinely GPU-resident Vulkan preparation/refinement path remains a future
  optimization. Current AMD support uses CPU preparation/refinement and GPU
  inference, with the measured latency tradeoff above.
