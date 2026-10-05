# PyroWave Zero-Copy GPU Pipeline (Quest 3)

> Status: Implemented, awaiting on-device stream testing. Validation step 1
> passed on Quest 3 (golden frame decoded through our own VkDevice into an RGBA
> AHardwareBuffer; all 8 patches within ±1 of exact). In-app, our own Vulkan
> device comes up at startup. Steps 2-4 are covered by the integrated build and
> need a live PyroWave stream to confirm. Follows on from `pyrowave-codec.md`
> (the CPU-round-trip integration merged in PR #46).
>
> Code: `pyrowave_gpu_pipeline.cpp/h` (device bootstrap, decode + conversion,
> slot ring), `texture_uploader.cpp/h` (`*_pyrowave_gpu_*`: EGLImage import,
> fence handoff, stable RID), `shaders/pyrowave_fullscreen.vert` + `pyrowave_yuv_to_rgba.frag` (compiled by
> CMake with the NDK's `glslc`). Logs to look for: `PyrowaveGpu: Zero-copy
> pipeline ready`, `TextureUploader: PyroWave GPU output ready`, and
> `PyrowaveDecoder: [TIMING] zero-copy decode-thread cost=...`. If setup fails,
> `falling back to CPU readback` is logged and the old path runs unchanged.

## Problem

Today PyroWave decode calls `pyrowave_decoder_decode_cpu_buffer_synchronous()`.
That function is GPU decode, then a blocking GPU-to-CPU readback, and then
Nightfall does a CPU-to-GPU upload into GLES textures. The decode thread blocks
for about 12-20ms per frame. The iDWT compute itself is about 10ms of GPU time
on Adreno 740 (PyroWave's standalone benchmark on this hardware), and most of
the rest is the round trip.

## What didn't work, and why (confirmed on-device, 2026-10-02)

The first design shared PyroWave's **YUV output planes** directly between
Vulkan and GLES. Two platform constraints rule that out:

1. **AHardwareBuffer:** PyroWave's decode writes each plane through a
   single-channel storage/attachment view, so it needs R8 (or R16) images.
   Quest 3's gralloc refuses `AHARDWAREBUFFER_FORMAT_R8_UNORM`, `R16_UINT` and
   `R16G16_UINT` for every usage combination tried (EIO/EPERM). NV12 allocates,
   but its chroma plane can only be reached through swizzled views, which can't
   be write targets. Vulkan requires identity swizzle for storage, and
   `pyrowave_image_get_image_view()` rejects it for the same reason.
2. **Raw dma-buf:** `/dev/dma_heap/system` *is* allocatable from the app
   process (Horizon OS sepolicy is looser than AOSP here, verified in-app).
   But Horizon's EGL (`1.5 Android META-EGL`) does not expose
   `EGL_EXT_image_dma_buf_import`, so GLES can't import a raw dma-buf.

The Granite AHardwareBuffer-import patch
(`tools/build_support/patches/granite-android-hardware-buffer-import.patch`)
was written for design 1. It works, but the design below doesn't need it (see
"Housekeeping").

## The design: only the final RGB frame crosses the API boundary

The mistake in the first design was assuming the YUV planes had to cross
APIs. They don't. `pyrowave.h` supports an app-owned Vulkan device:

- `pyrowave_create_device()` takes *our* VkInstance/VkDevice.
- With that path, "application should create its own images and set the image
  view struct without going through" `pyrowave_image_get_image_view()`. So
  the planes are ordinary Vulkan-internal R8 images. Gralloc is never involved
  for them, so its format restrictions don't apply.
- `pyrowave_device_set_command_buffer()` makes PyroWave record decode into
  *our* command buffer. We append our own pass and submit once.

Per frame:

```
[Vulkan, our device]                          [GLES, Godot render thread]
 PyroWave decode -> internal R8 Y/Cb/Cr
 our YUV->RGB pass (BT.709 limited range)
   -> RGBA8888 AHardwareBuffer (ring slot N)
 submit, export SYNC_FD semaphore  ------fd----> eglCreateSyncKHR(NATIVE_FENCE)
                                                 eglWaitSyncKHR  (GPU-side wait)
                                                 sample slot N texture (color_matrix_type=3)
 wait on GLES release fence for slot <---fd---- eglDupNativeFenceFDANDROID
```

The YUV-to-RGB conversion moves from the GLES display shader into the Vulkan
pass, so it isn't an added copy. The readback and the upload are gone.

### Capabilities this depends on (all verified on Quest 3)

| Requirement | Result |
|---|---|
| Vulkan 1.3 on Adreno 740 | yes |
| `VK_ANDROID_external_memory_android_hardware_buffer`, `VK_EXT_queue_family_foreign` | yes |
| RGBA8888 AHB allocates (2560x1440, SAMPLED+FRAMEBUFFER) | yes |
| RGBA8888 AHB imports to Vulkan with STORAGE / COLOR_ATTACHMENT usage | yes (dedicated alloc only) |
| Allocated AHB format features: STORAGE_IMAGE, COLOR_ATTACHMENT, SAMPLED | all yes, plain `VK_FORMAT_R8G8B8A8_UNORM` (no external-format/Ycbcr conversion needed) |
| `VK_KHR_external_semaphore_fd` with SYNC_FD export/import | yes |
| `EGL_ANDROID_get_native_client_buffer`, `EGL_ANDROID_image_native_buffer` | yes |
| `EGL_ANDROID_native_fence_sync`, `EGL_KHR_wait_sync` | yes |
| `glslc` for the conversion shader | ships in NDK `shader-tools/` |
| Wrapping a GL texture as a Godot RID | precedent: `texture_uploader.cpp` (`texture_create_from_native_handle`) |

This is the same basic architecture as `MoreOrLessSoftware/moonlight-android`
(app-owned Vulkan device, `pyrowave_decoder_decode_gpu_buffer`). The difference
is that we hand the result to GLES instead of presenting from Vulkan.

## Components to build

1. **Vulkan bootstrap (native addon).** Create our own VkInstance/VkDevice at
   `MODULE_INITIALIZATION_LEVEL_CORE`, the same slot as today's
   `pyrowave_warmup_device()`, because the Adreno driver fails device creation
   once a GLES context exists. Enable what PyroWave's decoder requires
   (Vulkan 1.3, subgroup basic/ballot/shuffle/arithmetic ops, subgroup size
   control) plus the AHB, queue-family-foreign and external-semaphore-fd
   extensions. Pass it to `pyrowave_create_device()`.
2. **Internal plane images.** Y (WxH) and Cb/Cr (W/2xH/2) R8_UNORM images with
   SAMPLED plus STORAGE or COLOR_ATTACHMENT usage. Which one depends on
   `pyrowave_decoder_device_prefers_fragment_path()`, which is true on this
   Adreno, so color attachments in `COLOR_ATTACHMENT_OPTIMAL`/`GENERAL`.
   Fill `pyrowave_image_view` manually.
3. **Output ring.** Three RGBA8888 AHardwareBuffers. Each one is imported once
   into Vulkan (dedicated allocation, `VkImportAndroidHardwareBufferInfoANDROID`)
   and once into GLES (`eglGetNativeClientBufferANDROID` ->
   `eglCreateImageKHR(EGL_NATIVE_BUFFER_ANDROID)` ->
   `glEGLImageTargetTexture2DOES(GL_TEXTURE_2D)`). Imports are set up once
   per stream, not per frame.
4. **Conversion pass.** A full-screen fragment pass (Adreno prefers fragment)
   that samples the 3 planes and writes RGBA into the ring slot. The BT.709
   limited-range math already exists in `PyrowaveDecoder::convert_to_rgba()`
   and `yuv_display_core.gdshaderinc`. Compile with `glslc` and embed the
   SPIR-V as a header. Queue-family transfer to and from
   `VK_QUEUE_FAMILY_FOREIGN_EXT` around the write.
5. **Sync.** Vulkan to GLES: export a SYNC_FD from the submit's signal
   semaphore, then `eglWaitSyncKHR` on the render thread before sampling.
   GLES to Vulkan: after Godot's frame that sampled slot N, take a native fence
   fd and import it as a temporary semaphore payload, then wait on it before
   reusing slot N. Three slots means the decode thread normally never waits.
6. **Godot wiring.** Wrap each slot's GL texture as a Godot RID once. Per
   frame, point `tex_y` at the current slot's RID with `color_matrix_type = 3`
   ("already RGB"), the same sentinel the MediaCodec OES path uses. Set
   `display_wired_` as today.
7. **Fallback.** If any capability check or import fails at stream setup,
   use the existing CPU-round-trip path unchanged. Never fail hard.

## Validation order

1. **Vulkan-only.** Bootstrap the device, decode the golden frame
   (`~/Development/Personal/pyrowave-golden/`) into internal planes, convert
   into one RGBA AHB, then CPU-readback via `AHardwareBuffer_lock`
   (RGBA8888 supports CPU read) and compare against expected RGB at the 8
   patch centres. Standalone binary over adb, as with the earlier probes.
2. **GLES import.** Fill an RGBA AHB with a known pattern and display it
   in-app through the EGLImage -> Godot RID path.
3. **End to end with coarse sync** (`vkQueueWaitIdle` + `glFinish`), to prove
   correctness separately from sync.
4. **Real fence sync and ring.** Measure decode-thread time,
   end-to-end latency and drops against the current 12-20ms baseline at
   1440p60/90/120.

## Expected payoff, honestly

- Removes the blocking readback and the CPU upload. The decode thread drops
  from ~12-20ms blocking to sub-millisecond record+submit, and frames can
  pipeline instead of serializing on the CPU.
- Does **not** make the iDWT faster. About 10ms of GPU time per frame remains,
  and it shares the GPU with Godot's rendering, passthrough and AI-3D. At 90Hz
  (11.1ms) that is tight. At 120Hz it will likely still drop frames, because
  the bottleneck becomes GPU throughput, not architecture.

## Housekeeping

- The Granite AHB-import patch and its `build_pyrowave_android.sh` hook were
  dropped. This design imports the RGBA buffers with raw Vulkan on our own
  device and runs against the unmodified vendored PyroWave library.
- Granite keeps 2 frame contexts and frees PyroWave's per-call image views when
  a context is recycled. That recycle waits on a fence submitted on the *next*
  decode call, after our command buffer, so the views outlive our use of them as
  long as each frame is submitted before the next `decode_frame()`. The decode
  loop guarantees this.
- The API-28 `libvulkan` stub only exports Vulkan 1.0/1.1 symbols, so 1.3 and
  extension entry points are fetched with `vkGetDeviceProcAddr`.

## Critical files

`addons/nightfall-stream/src/video/pyrowave_decoder.cpp/h` (device bootstrap,
GPU decode path, fallback), new `addons/nightfall-stream/src/video/pyrowave_gpu_bridge.cpp/h`
(AHB ring, Vulkan/EGL imports, sync, conversion pass), new conversion shader +
generated SPIR-V header, `addons/nightfall-stream/src/video/texture_uploader.cpp`
(RID wrapping, render-thread fence wait), `addons/nightfall-stream/src/video/stream_connection.cpp`
(wiring + fallback), `addons/nightfall-stream/src/register_types.cpp`
(CORE-level bootstrap), `addons/nightfall-stream/CMakeLists.txt` (link
`vulkan`, `EGL`, `GLESv3`, `android`; shader build step).
