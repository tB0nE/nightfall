# 4K Performance & Linux PCVR Optimization Plan

## Part 1: 4K@72fps on Quest (COMPLETED)
- ✅ Disabled stream_viewport when comp layer active
- ✅ Cached shader parameters (set only on change)
- ✅ Dropped MSAA 2X → disabled
- ✅ Throttled depth estimator get_depth_map() to submit interval
- ✅ Buffered log file writes
- ⏳ User testing: MSAA, smooth/sharpen filter on/off at 4K

## Part 2: Linux PCVR Performance & Quality

### 2A. Frame Pacing (Medium effort, high impact for stutter)

**Problem**: Decode thread delivers frames at Sunshine's cadence (60fps). WiVRn's OpenXR runtime vsyncs at Quest's refresh rate (72Hz). No synchronization between them. Comp viewports re-render every engine frame even when the decoded frame hasn't changed.

**Solution**: Flag-based frame pacing.
1. Add a `_frame_available: bool = false` flag in main.gd (or expose from native)
2. When the native decode thread uploads a new frame, set the flag to true
3. In `_process()`, only set comp viewport(s) to UPDATE_ONCE when `_frame_available` is true, then clear the flag
4. This avoids re-rendering the YUV→RGB SubViewport on frames where no new content arrived

**Implementation**:
- `texture_uploader.cpp`: After `perform_gpu_update()`, call a GDScript callback or set a flag
- `main.gd`: In `_process()`, check the flag and conditionally update comp viewports
- Alternative: Expose a `_new_frame` bool from stream_backend that the GDScript polls

**Expected impact**: Eliminates redundant comp viewport renders. At 60fps stream on a 72Hz display, ~17% of frames are redundant re-renders. More importantly, it aligns render timing with content availability, reducing perceived jitter.

### 2B. Zero-Copy VAAPI Texture Import (High effort, biggest win)

**Problem**: VAAPI decodes to GPU surface → memcpy to CPU PackedByteArray → rd->texture_update() back to GPU. At 4K60, this is ~1 GB/s of wasted bandwidth. On Android, MediaCodec delivers textures directly to GPU — zero copies.

**Solution**: Import VAAPI/Vulkan decoded image directly into Godot's RenderingDevice.
1. In `texture_uploader.cpp`, after VAAPI decode, extract the Vulkan image handle from the AVFrame
2. Use `rd->texture_create_from_extension()` to create a Godot texture from the existing Vulkan image
3. Bind this texture directly to the YUV shader — no CPU copies

**Key steps**:
- Export the VAAPI surface as a Vulkan image via `vaExportSurfaceHandle()` or derive from VAAPI's DRM fd
- Use Vulkan import (`VkImage`) to create a Godot RenderingDevice texture
- Update the shader to sample from the imported texture instead of the uploaded R8 buffers

**Challenges**:
- VAAPI↔Vulkan interop requires sharing the same DRM device
- Need to handle format conversion (NV12 VAAPI → separate Y/UV Vulkan textures)
- Godot's `texture_create_from_extension()` needs correct format and usage flags
- Synchronization: decoded surface must be ready before shader reads it (pipeline barrier)

**Expected impact**: Eliminates ~1 GB/s bandwidth at 4K60. Reduces decode-to-display latency by 1-2ms (no CPU round-trip). This is the single biggest Linux performance win.

### 2C. WiVRn Configuration (User action, no code changes)

Recommended user changes:
- Increase Sunshine bitrate significantly (80-100+ Mbps) — double compression means intermediate quality matters
- Consider H.264 for Sunshine stream at high bitrate — fewer artifacts per bit, since WiVRn re-encodes anyway
- Match Sunshine FPS to Quest refresh rate (72fps)
- Check WiVRn NVENC encode quality settings

### 2D. WiVRn Cylinder Layer Support (Informational)

WiVRn does NOT expose `XR_KHR_composition_layer_cylinder`. Godot falls back to rendering the comp layer as a 3D mesh in the scene. This works but:
- Double render (SubViewport → fallback mesh)
- Cylinder approximation (discrete vertices vs per-pixel ray intersection)
- No independent reprojection from the runtime

Decision: Keep current behavior — user confirms quality is still better than direct mesh path.

## Implementation Order

1. **Frame pacing** — flag-based, GDScript + small native change
2. **Zero-copy VAAPI** — significant C++ work, investigate Vulkan interop first
3. **User config tuning** — immediate, no code changes
