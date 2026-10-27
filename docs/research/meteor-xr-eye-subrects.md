# Projection-eye source regions and texture arrays

The 2026-10-19 controller/early-exit checkpoint is followed by an application
compatibility pass. The adapted hello_xr sample demonstrated independent OpenXR
rendering, but does not establish compatibility with arbitrary engine output.
The encoder previously required each eye to occupy an entire separate square
RGBA8 image. This increment removes the full-image restriction only.

## Implemented

Each eye may occupy a square 256- or 512-pixel region inside a larger RGBA8 UNORM
swapchain image. Source bounds and equal output eye sizes are checked before
encoding. Negative offsets, out-of-bounds regions, unsupported sizes and unequal
eye dimensions are rejected without implicit cropping/clamping/scaling.

The local encoder bridge carries per-eye source offsets. Vulkan copies that
region directly into the existing packed stereo encoder surface. Output/wire
dimensions, pose/FOV metadata and headset decoder/presenter remain unchanged.
There is no extra resize pass or CPU image readback in the encoder path.
Swapchain image leases and bounded raw/network workers remain in place.
The diagnostic bridge's struct-size check rejects mismatched producer/consumer
builds; rebuild both through the supported probe scripts.

## Validation

```bash
bash tools/build_support/probe_monado_runtime.sh --build
NIGHTFALL_XR_PADDED_SUBRECT=1 NIGHTFALL_XR_PROBE_FRAMES=32 \
  NIGHTFALL_XR_EYE_SIZE=512 NIGHTFALL_XR_TARGET_HZ=60 \
  NIGHTFALL_XR_ASYNC_ENCODE=1 NIGHTFALL_XR_ASYNC_DELIVERY=1 \
  NIGHTFALL_XR_FREE_RUNNING=1 \
  bash tools/build_support/probe_xr_transport.sh
```

The reference application creates images 32 pixels larger in each dimension,
clears them magenta, then writes asymmetric eye markers at offsets (8,12) and
(12,8). It submits only those regions. Application logs identify the actual
source dimensions/offsets; the harness requires those lines. Application
readbacks verify the fixture itself; decoded loopback markers verify the
GPU encoder crop (orientation, eye identity and border exclusion). The server
CPU-readback capture remains full-image only and rejects offset regions.
The padded fixture deliberately rejects GPU scene/hello_xr modes rather than
silently rendering a different layout.

Native region-bound tests run with every Monado/NVENC probe. The initial 512
async test passed with 32 submissions, 31 delivered frames, one pending raw
replacement, correct decoded markers and final drain. This is not an arbitrary
application, production-resolution benchmark or headset frame-rate claim.
The final fixture/evidence-check rerun passed with 32 submissions/27 delivered
frames; the unchanged full-image regression passed with 32/29. Both retained
strict marker validation, bounded worker accounting and final drain. Counts vary
with free-running compositor scheduling and are not throughput benchmarks.

## Shared texture-array eyes

The encoder also accepts submitted array slices, including both eyes referring
to the same swapchain image. Each source barrier/copy/release names that eye's
array slice explicitly; output is still one packed two-eye image. Image-use
leases remain per-eye and balanced even when both refer to one image, so a queued
eye cannot become writable merely because another reference was released.
Array bounds and sample count are checked before encode; multisampled sources
remain rejected rather than copied incorrectly.

Add `NIGHTFALL_XR_ARRAY_STEREO=1` to the transport probe. This flag selects the
reference fixture, not a production encoder policy: encoding follows the actual
submitted sub-images. The fixture creates one two-layer swapchain, acquires/waits
once per frame, writes both slices and releases once after both eyes are ready.
It deliberately maps left to slice 1 and right to slice 0. Fixture logs are
required by the harness. GPU scene/hello_xr fixture modes remain separate.

The combined 512-pixel cropped-array async test passed: 32 submitted/29 delivered,
correct decoded markers, balanced leases and final drain. There is no additional
CPU image readback or resize in the encoder path. This is not proof of arbitrary
engine formats, real-game support or Vulkan validation-layer coverage.
The 256-pixel shared-array stop-and-wait test also passed all 32 frames, with
marker validation and clean drain.

## Remaining real-application gates

1. Validate the [new RGBA/BGRA/sRGB source path](meteor-xr-source-formats.md) on
   the headset; other output sizes/aspect ratios and negotiated limits.
2. An engine-based OpenXR fixture and then a selected independent application,
   using process-local runtime selection and no SteamVR/global runtime changes.
3. Extra composition layers/depth/multisampling, performance and Windows gates.

No new Quest APK is needed for source-region support: it receives the same packed
frame layout. Do not claim game compatibility from the reference pattern test.
