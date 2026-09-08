# 4K Streaming Performance Optimization Plan

## Problem

Streaming at 4K (3840x2160) causes significant FPS drops compared to lower resolutions. WiVRn, a native C++ OpenXR streaming client, handles full display resolution on the same Quest 3S hardware without issue. This document identifies the bottlenecks and proposes optimizations.

## Current Rendering Pipeline

```
AVFrame (FFmpeg/MediaCodec decode)
  → CPU memcpy 3 planes (Y/U/V) (~16.6 MB/frame at 4K)
  → 3x RenderingDevice::texture_update() calls
  → SubViewport: YUV→RGB ColorRect shader (full 3840x2160 render pass)
  → Main XR multiview pass:
      stereo_screen.gdshader on MeshInstance3D (MSAA 2X)
        - Up to 14 texture samples/pixel/eye with smooth+sharpen enabled
        - Depth texture sampling in AI 3D mode
      + UI panel, keyboard, bezel, starfield, cursors
  → XR swapchain
  → xrEndFrame
```

**Total GPU passes for video content alone: 3+ per frame (YUV viewport + stereo multiview)**

## WiVRn Rendering Pipeline (for comparison)

```
Network packets
  → Shard accumulator
  → Hardware decoder → VkImage (zero-copy from decoder)
  → Single Vulkan render pass (defoveation + YUV conversion in one shader)
  → XR swapchain (XrCompositionLayerProjection)
  → xrEndFrame
```

**Total GPU passes for video content: 1 per frame. No engine overhead. No intermediate render targets.**

## Bottleneck Analysis

| Bottleneck | 4K Cost | WiVRn Equivalent | Severity |
|-----------|---------|-----------------|----------|
| CPU→GPU texture upload | ~16.6 MB/frame, ~1 GB/s at 60fps | Single VkImage, zero-copy from decoder | High |
| YUV SubViewport render pass | Full 3840x2160 render pass just for color space conversion | Handled in defoveation pass (merged) | High |
| stereo_screen.gdshader | Up to 14 texture samples/pixel/eye with smooth+sharpen | 1 texture sample/pixel | Medium-High |
| Godot Forward+ multiview | Entire scene rendered twice (MSAA 2X): screen, UI, keyboard, bezel, starfield, cursors | No scene graph — only the video quad | Medium |
| Detection viewport | Extra downsampling pass every 0.3s | Not applicable | Low |
| MSAA 2X | Doubles sample count for all 3D geometry (screen mesh, bezel, grab bars, keyboard) | Not applicable | Low-Medium |

## Optimization Proposals

### Phase 1: Quick Wins (within current Godot architecture)

#### 1.1 Merge YUV conversion into stereo_screen.gdshader

**Current**: YUV→RGB happens in a separate SubViewport (ColorRect with yuv_shader), then the stereo_screen shader samples the converted RGB texture.

**Proposed**: Sample the Y/U/V plane textures directly in stereo_screen.gdshader and perform YUV→RGB conversion there. Eliminates the SubViewport render pass entirely.

**Savings**: 1 full-resolution render pass per frame (~8.3M pixels at 4K per eye in multiview).

**Implementation notes**:
- The stereo_screen shader needs 3 uniform sampler2D inputs for Y/U/V planes instead of (or in addition to) the single `main_texture`
- The YUV→RGB color matrix code from `yuv_shader.h` needs to be ported to GLSL in the stereo_screen shader
- The `depth_texture` uniform and YUV plane uniforms can coexist
- The `filtered_texture()` helper would sample from Y/U/V planes and convert before applying blur/sharpen
- Need to handle NV12 vs YUV420P format distinction (NV12: interleaved UV in a single plane)

**Risk**: Low. Shader change only. No C++ changes needed.

#### 1.2 Skip smooth/sharpen at high resolutions

**Current**: `filtered_texture()` performs up to 14 texture samples per pixel when smooth+sharpen is active, regardless of resolution.

**Proposed**: When streaming at 4K (or when `filter_mode == 0 && sharpen <= 0.0`), the shader already returns the original texture with zero extra samples. But users may have smooth/sharpen enabled. Add a resolution-aware bypass: at 4K, smooth is rarely needed (pixels are already dense), so default to off and optionally skip the filter path.

**Savings**: ~13 extra texture samples per pixel per eye at 4K when smooth/sharpen is on.

**Risk**: Very low. Just UI default + optional shader short-circuit.

### Phase 2: Medium Effort (C++ plugin changes)

#### 2.1 Zero-copy decoder output via VkImage import

**Current**: Decoded frames are `memcpy`'d from AVFrame data pointers into Godot `PackedByteArray` buffers, then uploaded via `RenderingDevice::texture_update()`. This is ~16.6 MB of CPU→GPU bandwidth per frame at 4K60.

**Proposed**: Import the decoder's output `VkImage` directly into Godot's RenderingDevice using `RenderingDevice::texture_create_from_extension()`. This creates a Godot texture RID that wraps the existing Vulkan image — no copy, no upload.

**Savings**: Eliminates ~1 GB/s CPU→GPU bandwidth. Eliminates `memcpy` overhead. Eliminates `texture_update()` GPU stalls.

**Implementation notes**:
- MediaCodec on Android outputs `AHardwareBuffer` which can be imported as a `VkImage` via `VK_ANDROID_external_memory_android_hardware_buffer`
- FFmpeg software decode outputs `AVFrame` with `data[]` pointers — these would still need `memcpy` (software decode is a fallback)
- Need to add Vulkan interop code in `texture_uploader.cpp`:
  - Get the `VkImage` handle from the decoder
  - Call `rd->texture_create_from_extension()` with the VkImage
  - Create a Godot texture RID wrapping it
- Need to handle format compatibility (R8 plane textures vs NV12 hardware buffer)
- Synchronization: must ensure decoder has finished writing before Godot reads. Use VkSemaphore or pipeline barrier.

**Risk**: Medium. Requires Vulkan interop code. Android-specific path. May need careful synchronization.

#### 2.2 Reduce Godot scene complexity during streaming

**Current**: The full Godot scene renders every frame: screen mesh, UI panel, keyboard, bezel, corner handles, starfield, cursor pointers, grab bars.

**Proposed**: When streaming, hide non-essential 3D nodes (bezel, corner handles, grab bars, starfield) if UI is not visible. Only render the screen mesh + cursor. This reduces the Forward+ multiview pass work.

**Savings**: Reduces vertex count and draw calls in the multiview pass. MSAA cost applies to fewer triangles.

**Risk**: Low. Just visibility toggles.

### Phase 3: Significant Effort (architectural changes)

#### 3.1 OpenXR compositor quad layer for video content

**Current**: The video is rendered through Godot's full Forward+ rendering pipeline as a MeshInstance3D with a ShaderMaterial. This means the entire scene (including video) goes through multiview rendering, MSAA, tonemapping, etc.

**Proposed**: Use an `XrCompositionLayerQuad` to present the video texture directly to the OpenXR runtime, bypassing Godot's rendering pipeline entirely. The UI, keyboard, etc. would still render through Godot, but the video texture would be composited by the OpenXR runtime as a separate layer.

**Savings**: Eliminates Godot's Forward+ multiview pass for the video content. The OpenXR runtime composites the quad layer efficiently (single texture sample + blend). No MSAA cost for the video.

**Implementation notes**:
- Godot's OpenXR plugin does not currently expose `xrCreateSwapchain` or `XrCompositionLayerQuad` to GDScript
- Would need to modify the Godot OpenXR plugin (C++) or create a custom OpenXR extension:
  - Create a separate swapchain for the video quad
  - Render the YUV→RGB converted (and stereo-processed) video into this swapchain
  - Submit it as a `XrCompositionLayerQuad` alongside Godot's projection layer
- The quad layer would be positioned/oriented the same as the current screen mesh
- Could combine with Phase 1 (YUV conversion in the video swapchain shader)
- The Godot scene would only render the UI panel, keyboard, bezel — much lighter

**Risk**: High. Requires Godot engine/plugin modifications. Not possible from GDScript alone.

#### 3.2 Foveated rendering

**Current**: The entire video frame is rendered at full resolution by the stereo_screen shader.

**Proposed**: Like WiVRn, implement foveated rendering where the center of the screen is full resolution but the periphery is rendered at reduced resolution. This dramatically reduces the pixel shader workload, especially at 4K.

**Implementation notes**:
- Server-side: Sunshine/NVIDIA supports foveated encoding (lower encode quality at periphery)
- Client-side: The stereo_screen shader could use a variable-resolution mesh or UV remapping to reduce fragment count at edges
- WiVRn's approach: server encodes a foveated image, client "defoveates" it with a custom mesh in a single Vulkan render pass
- Could be combined with Phase 3.1 (quad layer with foveation mesh)

**Risk**: High. Requires both server-side and client-side changes. Complex to implement correctly.

## Priority Recommendation

| Phase | Item | Impact | Effort | Priority |
|-------|------|--------|--------|----------|
| 1.1 | Merge YUV into stereo shader | High (1 render pass eliminated) | Low | **Highest** |
| 1.2 | Skip smooth/sharpen at 4K | Medium | Very Low | **High** |
| 2.2 | Reduce scene complexity | Medium | Low | Medium |
| 2.1 | Zero-copy VkImage import | High | Medium | Medium |
| 3.1 | OpenXR quad layer | Very High | High | Long-term |
| 3.2 | Foveated rendering | Very High | Very High | Long-term |

## Measured Performance Reference

| Resolution | Current FPS (approx) | WiVRn FPS |
|-----------|---------------------|-----------|
| 1280x720 | 120 | Full refresh rate |
| 1920x1080 | 90-120 | Full refresh rate |
| 2560x1440 | 60-72 | Full refresh rate |
| 3840x2160 | 30-45 | Full refresh rate |

Note: Actual FPS varies based on stream FPS setting, smooth/sharpen mode, AI 3D mode, and passthrough mode. The above reflects 4K at 60fps stream setting with default shader settings.

## Related Files

- `src/shaders/stereo_screen.gdshader` — Main video rendering shader
- `addons/nightfall-stream/src/video/texture_uploader.cpp` — GPU texture upload
- `addons/nightfall-stream/src/video/yuv_shader.h` — YUV→RGB shader code
- `addons/nightfall-stream/src/video/stream_connection.cpp` — Decode pipeline
- `addons/nightfall-stream/src/video/ffmpeg_decoder.cpp` — Decoder configuration
