# PyroWave Zero-Copy GPU Pipeline (Quest 3)

> Status: Active — planning only, not started. Follows on from
> `pyrowave-codec.md` (the working, CPU-round-trip integration already
> shipped on `feat/add_pyrowave`).

## Problem

PyroWave decode on this Quest 3 costs ~10-17ms per frame on the decode
thread (measured via direct in-app timing, and independently confirmed by
PyroWave's own standalone CLI test harness reporting the same ~10ms total
for `iDWT`+`Dequant`+`Packing`+`Resolve` on this exact hardware, in total
isolation with zero app/GPU contention). That rules out Nightfall's own
architecture or GPU contention with Godot's rendering as the cause — this is
genuinely how long this GPU workload takes on this mobile SoC (Adreno 740 in
Snapdragon XR2 Gen 2) today, nowhere close to PyroWave's own advertised
<0.1ms (1080p) / <0.2ms (4K) figures, which are desktop-discrete-GPU numbers
(the host side of this integration was benchmarked on an RTX 3090).

At 2560x1440@60 this fits inside budget with some margin. At 90/120Hz it
won't, and the single largest chunk of that cost is **not** the actual
wavelet transform compute shader — it's `pyrowave_decoder_decode_cpu_buffer_synchronous()`,
which pyrowave.h's own header explicitly calls "mostly for bringup testing":
GPU decode, then a full synchronous GPU→CPU memory readback. Nightfall then
does a second CPU→GPU copy to get the result into a sampleable texture. Two
full round-trips across the CPU/GPU boundary, every single frame.

## Why the reference client doesn't pay this cost

`MoreOrLessSoftware/moonlight-android`'s PyroWave decoder
(`app/src/main/jni/vulkan/pyrowave_decoder.cpp`) uses `pyrowave_create_device`
(not `pyrowave_create_default_device`) and `pyrowave_decoder_decode_gpu_buffer`
(not the CPU buffer API) — PyroWave decodes directly into a GPU image that
app owns. It gets away with zero cross-API copying because its *entire app*
is Vulkan-native (own `vulkan_renderer.cpp`, own `VkSwapchain`, own
`ANativeWindow` surface) — the decoded image is already native to the same
API the renderer consumes it with. No bridge needed, because there's nothing
to bridge.

Nightfall runs Godot's `gl_compatibility` (GLES3) renderer, not Vulkan
(switched from a Vulkan/AHardwareBuffer pipeline on 2026-08-23, `7e0ca91` —
no documented rationale; worth revisiting separately, but out of scope
here). That means PyroWave's GPU-resident output has to cross an API
boundary to reach the screen, which is exactly the thing this plan is about.

## What's actually missing

PyroWave's GPU-buffer path (`pyrowave_decoder_decode_gpu_buffer`) requires
images the app supplies, which can be **externally imported** memory
(`pyrowave_image_create()` with an `external_handle` + `handle_type`). This
function is fully implemented and handle-type-agnostic — it forwards
straight to the underlying Granite engine's `device.create_image()` with
`IMAGE_MISC_EXTERNAL_MEMORY_BIT`, and that already works for `DMA_BUF`
(Linux/Wayland capture) and `D3D11`/`D3D12` (Windows, with an NVIDIA-specific
workaround already in place).

**It has never been wired up for `VK_ANDROID_external_memory_android_hardware_buffer`.**
Confirmed by grepping all of Granite (the engine PyroWave is built on) for
`AHardwareBuffer`/`ANDROID_HARDWARE_BUFFER`: zero hits outside the Vulkan
headers themselves. This is PyroWave's own `// TODO: Add support for
importing external memory as GPU buffers.` comment, still present at
upstream HEAD (we're already pinned to it, commit `89f7e47`) — there is no
newer version to pull that already has this.

Both PyroWave and Granite are open source and **we already build them from
source** (`tools/build_support/build_pyrowave_android.sh`), so this is not
blocked on upstream shipping a feature — it's blocked on nobody having
written the AHardwareBuffer import path yet, on either the Vulkan side
(Granite) or the GLES side (us).

## The three pieces of actual work

### 1. Granite: AHardwareBuffer import (new code, Vulkan side)

`VK_ANDROID_external_memory_android_hardware_buffer` has a different import
mechanism than DMA_BUF or the D3D handle types already supported:

1. `vkGetAndroidHardwareBufferPropertiesANDROID()` on the `AHardwareBuffer*`
   to get memory requirements and a compatible memory type index.
2. `vkAllocateMemory()` with a `VkImportAndroidHardwareBufferInfoANDROID`
   chained into `pNext`, importing that exact buffer.
3. Bind the already-created `VkImage` (created with
   `VkExternalMemoryImageCreateInfo` specifying
   `VK_EXTERNAL_MEMORY_HANDLE_TYPE_ANDROID_HARDWARE_BUFFER_BIT_ANDROID` in
   its own `pNext`) to that memory via `vkBindImageMemory2`.

This needs to land in Granite's `Device::create_image()` (or an adjacent
helper) as a new case, parallel to the existing DMA_BUF path — a real patch
to our vendored fork, not a config flag.

### 2. Nightfall: GLES-side import of the same buffer

Separately, GLES needs to see the *same* `AHardwareBuffer` as a sampleable
texture: `eglGetNativeClientBufferANDROID()` → `eglCreateImageKHR()`
(`EGL_NATIVE_BUFFER_ANDROID` target) → `glEGLImageTargetTexture2DOES()`,
producing a `GL_TEXTURE_EXTERNAL_OES` texture.

The existing MediaCodec OES-bridge code
(`texture_uploader.cpp`'s `create_android_gles_decoder_surface()` /
`update_android_gles_external_texture()`, currently dead - gated behind
`supports_android_hardware_buffer_import()`, which hardcodes `false` on
`gl_compatibility`) is a useful *reference* for the GLES-side plumbing
pattern, but not directly reusable: that code consumes a `SurfaceTexture`
MediaCodec itself produces, not an `AHardwareBuffer` we allocate ourselves.
This needs new code, following that one as a template.

**Format question to resolve early**: PyroWave decodes to planar YUV420P
(separate Y/Cb/Cr, per `pyrowave_image_view`'s own docs on plane aspects and
`VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT`). Whether an `AHardwareBuffer` in a
YUV420/NV12-family format can round-trip through both a Vulkan planar image
import *and* GLES's automatic external-OES YUV→RGB conversion needs to be
verified directly - if the automatic OES conversion doesn't use BT.709
limited-range (matching the host's actual encode), we may need to bypass it
and sample the Y/Cb/Cr planes directly via aspect-based texture views
instead (same math we already have working in the shader today), just
GPU-resident instead of CPU-uploaded.

### 3. Cross-API GPU synchronization (the hard part)

PyroWave's Vulkan compute write and GLES's sampling read touch the same
memory from two different APIs that don't know about each other's
scheduling. Needs real GPU-side sync, not a CPU-side `vkQueueWaitIdle`
stall (which would just reintroduce a blocking wait, defeating the point):

- Export a Vulkan semaphore as a sync fd (`VK_KHR_external_semaphore_fd`)
  after PyroWave's decode submission.
- Import that fd into EGL as `EGL_ANDROID_native_fence_sync` and wait on it
  before GLES samples the texture.
- `pyrowave_decoder_decode_gpu_buffer()`'s own `acquire`/`release`
  `pyrowave_gpu_sync_operation` parameters are exactly the hook point for
  this - they're how the app tells PyroWave which queue family doesnship the
  image before/after its own decode submission.

This is the single most failure-prone part of the whole design, and the one
most worth validating in isolation before touching the other two pieces.

## Suggested validation order (de-risk before integrating)

1. **Vulkan-only correctness check, no GLES at all.** Patch Granite for
   AHardwareBuffer import, allocate a buffer, decode a real frame into it via
   `pyrowave_decoder_decode_gpu_buffer()`, then do a *one-time, test-only* CPU
   readback (`vkMapMemory` or similar) purely to verify pixel correctness -
   reusing the same golden-frame comparison approach already used earlier
   in this project (`~/Development/Personal/pyrowave-golden/`). This proves
   the Vulkan-side import actually works before any GLES code exists.
2. **GLES import + static display**, no PyroWave yet: allocate an
   `AHardwareBuffer`, fill it with a known test pattern from the CPU side,
   import into GLES via EGLImage, confirm it renders correctly through the
   existing shader path. Proves the GLES half independently.
3. **Wire the two together** with a coarse, correctness-first sync strategy
   (even a temporary CPU-side stall is fine here, to isolate "is the
   cross-API handoff correct" from "is it fast").
4. **Only then** implement the real semaphore/fence-based sync and measure
   whether it actually beats the current ~12-20ms CPU-round-trip baseline by
   enough to matter.

## Fallback behavior

If AHardwareBuffer import fails at creation time (format unsupported,
driver rejects the extension, etc.), fall back automatically to the current
CPU-round-trip path (`pyrowave_decoder_decode_cpu_buffer_synchronous` +
GPU-shader YUV→RGB conversion) - matching the pattern already used
elsewhere in this codebase (native-XR-renderer falling back to the legacy
composition path on unsupported configurations). Never a hard failure.

## Effort / risk assessment

This is genuine multi-day, two-graphics-API engineering work, not a small
patch - realistically the biggest remaining risk is step 3 (cross-API sync),
which is the kind of thing that can silently produce visually-plausible but
subtly-wrong output (torn frames, stale data one frame behind) if done
incorrectly, rather than an obvious crash. Recommend treating this as its
own scoped effort with on-device validation at each of the four steps above
individually, not as one combined implementation - matching how the
original `pyrowave-codec.md` integration was done (small, independently
verified phases, each confirmed on-device before the next began).

## Expected payoff

If it works: PyroWave's per-frame cost on the decode thread drops from the
current ~12-20ms (GPU decode + CPU readback + GPU reupload) to something
close to the actual wavelet-transform compute time alone (~10ms on this
hardware per the standalone benchmark, likely slightly less once the
readback/reupload overhead is removed), making 90/120Hz realistic instead
of CPU-round-trip-bound. It does **not** make PyroWave decode as fast on
this mobile GPU as the <0.2ms desktop figures suggest - that gap is compute
throughput, not architecture, and nothing short of real hardware
acceleration (which doesn't exist for PyroWave on any platform today) closes
it.

## Critical files

`tools/build_support/build_pyrowave_android.sh` (vendoring/build script -
will need a Granite source patch step), `addons/nightfall-stream/third_party/pyrowave/`
(vendored headers/lib), `addons/nightfall-stream/src/video/pyrowave_decoder.cpp/h`
(decoder wrapper - needs a GPU-buffer code path alongside the existing CPU
one), `addons/nightfall-stream/src/video/texture_uploader.cpp/h` (new
AHardwareBuffer/EGLImage import code, informed by but not copied from the
existing dead MediaCodec OES-bridge functions), `addons/nightfall-stream/src/video/stream_connection.cpp`
(wiring + fallback-on-failure logic).
