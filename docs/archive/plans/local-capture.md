# v0.8.0: Local Capture Mode — Detailed Implementation Plan

## Overview

When the Nightfall client runs on the same Linux machine as the Sunshine server (e.g., via WiVRn on Linux PCVR), avoid the double-encoding penalty by capturing raw desktop frames and audio directly via PipeWire/DMA-BUF, while using Sunshine solely for controller/input.

**Current pipeline (remote):**
```
Desktop -> Sunshine encode -> Network -> Nightfall FFmpeg decode -> TextureUploader -> screen_mesh
```

**New pipeline (local):**
```
Desktop -> PipeWire ScreenCast (DMA-BUF) -> mmap + TextureUploader -> screen_mesh
Desktop audio -> PipeWire monitor capture -> Godot AudioStreamPlayback
Controllers -> Sunshine (minimal stream, discard video) -> input_bridge (unchanged)
```

---

## 1. Localhost Detection & Mode Switch

### 1.1 Detect Local Server

**File:** `src/stream_manager.gd`

Add `_is_local_host(ip: String) -> bool`:
- Check `ip` against `127.0.0.1`, `::1`, `localhost`
- Check `ip` against `IP.get_local_addresses()` (all local interface IPs)
- Store result in `local_capture_mode: bool`

### 1.2 Mode-Dependent Connection Parameters

**File:** `src/stream_manager.gd` — `start_stream()`

When `local_capture_mode == true`:
- Set Sunshine stream params to minimum viable values:
  - `width = 320`, `height = 240`, `fps = 1`, `bitrate = 500`
  - `packet_size = 1024`
- These satisfy Moonlight protocol validation (height must be even, all > 0)
- Sunshine still encodes at 320x240@1fps — negligible CPU/GPU cost
- The ENet control channel on port 47999 operates independently from video

### 1.3 Disable Client-Side Video Watchdog

**File:** `addons/nightfall-stream/src/video/stream_connection.cpp`

The moonlight-common-c library terminates the connection if no video traffic arrives:
- `ML_ERROR_NO_VIDEO_TRAFFIC = -100` (no UDP 47998 packets within timeout)
- `ML_ERROR_NO_VIDEO_FRAME = -101` (no complete frame assembled)

When `local_capture_mode == true`:
- In the video decode callback, immediately return without processing frames
- Suppress both watchdog errors — allow the connection to persist
- The ENet control channel keeps pinging independently; Sunshine won't timeout as long as pings arrive (default 10s timeout)

### 1.4 Expose Mode to GDExtension

**File:** `addons/nightfall-stream/src/nightfall_stream.cpp`, `nightfall_stream.h`

Add bound method `_set_local_capture_mode(enabled: bool)` that stores the flag in C++. The video decode path checks this flag to decide whether to process or discard frames.

### 1.5 UI Indicator

**File:** `src/ui_controller.gd`

When `local_capture_mode == true`, show a "Local Capture" badge in the status bar so the user knows video comes from PipeWire, not Sunshine.

---

## 2. PipeWire ScreenCast Portal — Video Capture

### 2.1 D-Bus Portal Session Lifecycle

**New files:**
- `addons/nightfall-stream/src/video/pipewire_capture.cpp`
- `addons/nightfall-stream/src/video/pipewire_capture.h`

The ScreenCast portal session follows this exact sequence:

#### Step 1: Read Portal Properties

D-Bus call on `org.freedesktop.portal.ScreenCast` at `/org/freedesktop/portal/desktop`:
- Read `version` (uint32) — must be >= 4 for persist_mode/restore_token support
- Read `AvailableSourceTypes` (uint32) — bitmask: 1=MONITOR, 2=WINDOW, 4=VIRTUAL
- Read `AvailableCursorModes` (uint32) — bitmask: 1=Hidden, 2=Embedded, 4=Metadata

#### Step 2: CreateSession

Method: `org.freedesktop.portal.ScreenCast.CreateSession`

Options dict:
| Key | Type | Value |
|-----|------|-------|
| `handle_token` | s | `"nightfall_screencast"` |
| `session_handle_token` | s | `"nightfall_session"` |

Response (via `org.freedesktop.portal.Request::Response` signal):
- `session_handle` (s): Object path like `/org/freedesktop/portal/session/.../nightfall_session`

#### Step 3: SelectSources

Method: `org.freedesktop.portal.ScreenCast.SelectSources`

Options dict:
| Key | Type | Value | Purpose |
|-----|------|-------|---------|
| `types` | u | 1 | MONITOR only (full display capture) |
| `cursor_mode` | u | 2 | Embedded (cursor baked into frames) |
| `multiple` | b | false | Single display |
| `persist_mode` | u | 2 | Persist until explicitly revoked |
| `restore_token` | s | saved token or `""` | Restore previous display selection |

If a valid restore_token is provided and the monitor still exists, the portal skips the interactive display picker.

#### Step 4: Start

Method: `org.freedesktop.portal.ScreenCast.Start`

- `parent_window` (s): `""` (no parent window for VR apps)
- Options: `handle_token` only

Response:
- `streams` (a(ua{sv})): Array of `(node_id, properties)` tuples
  - `node_id` (u): PipeWire node ID (deprecated in v6, still needed for `pw_stream_connect`)
  - Properties: `size` ((ii)), `position` ((ii)), `source_type` (u), `id` (s), `pipewire-serial` (t, v6+)
- `restore_token` (s): **New token — single-use, must be saved after each Start**

#### Step 5: OpenPipeWireRemote

Method: `org.freedesktop.portal.ScreenCast.OpenPipeWireRemote`

- Returns: File descriptor (D-Bus `h` type)
- This FD creates a restricted PipeWire connection where only screencast nodes are visible

### 2.2 D-Bus Implementation

**New files:**
- `addons/nightfall-stream/src/video/dbus_portal.cpp`
- `addons/nightfall-stream/src/video/dbus_portal.h`

Use **sd-bus** (from `libsystemd`, available on all modern Linux) for D-Bus communication.

Key implementation details:
- All portal methods are **asynchronous** — they return a Request handle, response comes via D-Bus signal
- Use `sd_bus_match_signal()` to subscribe to `org.freedesktop.portal.Request::Response` signals
- Use an eventfd or pipe to signal completion from the D-Bus callback to the PipeWire thread
- The session handle from CreateSession is used in all subsequent calls
- Response codes: `0` = Success, `1` = Cancelled (user dismissed dialog), `2` = Other error

### 2.3 Restore Token Persistence

**File:** `src/state_manager.gd`

- Save `restore_token` in `user://app_state.cfg` under section `local_capture`, key `restore_token`
- On startup, load the token and pass it to the GDExtension before starting capture
- After each successful Start, the GDExtension emits a signal with the new token — GDScript saves it
- If the token is rejected (portal returns error or prompts the user again), clear the stored token and continue

**File:** `addons/nightfall-stream/src/video/pipewire_capture.cpp`

- Expose `_set_restore_token(token: String)` and signal `restore_token_updated(String)`
- Pass the token in `SelectSources` options dict
- On Start response, extract the new token and emit the signal

### 2.4 PipeWire Stream Setup

After `OpenPipeWireRemote` returns the FD:

```cpp
pw_init(NULL, NULL);
struct pw_context *context = pw_context_new(loop, NULL, 0);
struct pw_core *core = pw_context_connect_fd(context, fd, NULL, 0);

struct pw_stream *stream = pw_stream_new(core, "nightfall-screencast",
    pw_properties_new(
        PW_KEY_MEDIA_CLASS, "Video/Source",
        PW_KEY_TARGET_OBJECT, serial_string,  // v6+: prefer serial over node_id
        NULL));

pw_stream_connect(stream,
    PW_DIRECTION_INPUT,       // receiving frames
    node_id,                  // from Start response (or PW_ID_ANY with TARGET_OBJECT)
    PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS,
    params, n_params);
```

### 2.5 Format Negotiation

In the `param_changed` callback (id == `SPA_PARAM_Format`):

```cpp
static void on_param_changed(void *data, uint32_t id,
                             const struct spa_pod *param) {
    if (param == NULL || id != SPA_PARAM_Format) return;

    struct spa_video_info_raw info;
    spa_format_video_raw_parse(param, &info);

    // Store for later texture creation:
    captured_format = info.format;       // e.g., SPA_VIDEO_FORMAT_BGRx, NV12
    captured_modifier = info.modifier;   // DRM format modifier (uint64_t)
    captured_size = {info.size.width, info.size.height};
}
```

When offering formats (EnumFormat param builder):
1. Query Vulkan for supported format+modifier combinations via `vkGetPhysicalDeviceFormatProperties2`
2. Build a POD with `SPA_POD_PROP_FLAG_DONT_FIXATE` listing supported modifiers
3. Prefer `DRM_FORMAT_MOD_LINEAR` as safest option; accept vendor modifiers if Vulkan supports them
4. After compositor picks a format, **fixate** by re-issuing `pw_stream_update_params()` with a single chosen modifier

### 2.6 Frame Processing (process callback)

```cpp
static void on_process(void *data) {
    struct pw_buffer *pw_buf = pw_stream_dequeue_buffer(stream);
    if (!pw_buf) return;

    struct spa_buffer *spa_buf = pw_buf->buffer;

    if (spa_buf->datas[0].type == SPA_DATA_DmaBuf) {
        for (uint32_t i = 0; i < spa_buf->n_datas; i++) {
            struct spa_data *d = &spa_buf->datas[i];
            plane_fds[i] = d->fd;
            plane_offsets[i] = d->mapoffset;
            plane_strides[i] = d->chunk->stride;
        }
        frame_available = true;
    } else if (spa_buf->datas[0].type == SPA_DATA_MemFd ||
               spa_buf->datas[0].type == SPA_DATA_MemPtr) {
        // Fallback: CPU-accessible data - use existing TextureUploader path
    }

    // Hold buffer until GPU import is done (see 2.7)
}
```

**Critical:** For DMA-BUF, we must hold the PipeWire buffer (not requeue it) until the GPU has imported the memory. We can only hold one buffer at a time. If a second frame arrives before the first is consumed, queue the old buffer back and dequeue the new one.

### 2.7 Buffer Lifecycle Management

Since we must hold PipeWire buffers while their DMA-BUF FDs are in use:

1. Track `current_pw_buffer` — the buffer currently being displayed
2. On each `on_process` call:
   - If `current_pw_buffer` is set, queue it back first
   - Dequeue the new buffer, store as `current_pw_buffer`
   - Signal frame availability
3. On cleanup, queue back any held buffer

This means we always display the latest frame (no queuing), which is ideal for VR latency.

### 2.8 PipeWire Thread

Run a dedicated `pw_thread_loop` for the PipeWire main loop:
- D-Bus portal calls happen on a separate thread (sd-bus has its own event loop)
- After portal session is established and PipeWire stream is connected, `pw_thread_loop` handles all stream events
- Use a condition variable or atomic flag to signal the render thread when a new frame is available

### 2.9 Session Cleanup

On disconnect or app exit:
1. Close the portal session: `org.freedesktop.portal.Session.Close` via D-Bus
2. Disconnect the PipeWire stream: `pw_stream_disconnect()`
3. Destroy the PipeWire context and loop
4. Clean up any imported Vulkan resources

---

## 3. DMA-BUF to Texture Pipeline

### 3.1 CPU-Copy Fallback Path (v0.8.0 Default)

**New files:**
- `addons/nightfall-stream/src/video/dmabuf_importer.cpp`
- `addons/nightfall-stream/src/video/dmabuf_importer.h`

For the initial implementation, mmap the DMA-BUF FDs and copy pixel data into the existing `TextureUploader`:

```cpp
void DmaBufImporter::import_frame(struct spa_buffer *spa_buf,
                                   uint32_t width, uint32_t height,
                                   uint32_t format) {
    for (uint32_t i = 0; i < spa_buf->n_datas; i++) {
        struct spa_data *d = &spa_buf->datas[i];
        if (d->type == SPA_DATA_DmaBuf && d->fd >= 0) {
            void *map = mmap(NULL, d->maxsize, PROT_READ,
                             MAP_PRIVATE, d->fd, d->mapoffset);
            if (map == MAP_FAILED) continue;

            uint8_t *src = (uint8_t *)map + d->chunk->offset;
            uint32_t src_stride = d->chunk->stride;
            // Copy into TextureUploader's plane buffers,
            // handling stride mismatch with line-by-line memcpy

            munmap(map, d->maxsize);
        }
    }

    // Reuse existing pipeline
    texture_uploader->update_from_raw_nv12(plane_y_data, plane_uv_data,
                                            width, height);
}
```

This reuses the entire existing YUV shader pipeline — no new GPU code needed. The cost is one CPU memcpy per frame, which for a local machine is still vastly better than the double-encode/decode penalty.

### 3.2 Format Handling

Common formats from PipeWire ScreenCast:

| SPA Format | DRM Format | Planes | Notes |
|------------|-----------|--------|-------|
| `SPA_VIDEO_FORMAT_BGRx` | `DRM_FORMAT_XRGB8888` | 1 | Most common on Wayland compositors |
| `SPA_VIDEO_FORMAT_RGBx` | `DRM_FORMAT_BGRX8888` | 1 | Byte-order variant |
| `SPA_VIDEO_FORMAT_NV12` | `DRM_FORMAT_NV12` | 2 | Semi-planar YUV, common on Intel |
| `SPA_VIDEO_FORMAT_YUV420P` | `DRM_FORMAT_YUV420` | 3 | Planar YUV |

For RGB formats (BGRx/RGBx), we need a new shader path or convert to NV12/YUV420P. The simplest approach:
- If format is BGRx/RGBx: mmap, copy into a PackedByteArray, create a Godot `Image` from RGB data, upload as `DATA_FORMAT_R8G8B8A8_UNORM` texture
- If format is NV12: use existing `update_from_raw_nv12()` path
- If format is YUV420P: use existing `update_from_frame()` path

### 3.3 Zero-Copy Vulkan Import Path (Future Optimization)

For a later release, the zero-copy path would:

1. **Get Vulkan handles from Godot:**
   ```cpp
   VkDevice device = (VkDevice)rd->get_driver_resource(
       RenderingDevice::DRIVER_RESOURCE_VULKAN_DEVICE, RID(), 0);
   // Also: INSTANCE, PHYSICAL_DEVICE, QUEUE, QUEUE_FAMILY_INDEX
   ```

2. **Create VkImage** with pNext chain:
   ```
   VkImageCreateInfo
     -> VkExternalMemoryImageCreateInfo (handleTypes = DMA_BUF_BIT_EXT)
       -> VkImageDrmFormatModifierExplicitCreateInfoEXT (modifier + plane layouts)
   ```
   - `tiling` must be `VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT`
   - Plane layouts from `spa_data[i]`: offset = `mapoffset`, rowPitch = `chunk->stride`

3. **Import memory:**
   ```
   VkMemoryAllocateInfo
     -> VkImportMemoryFdInfoKHR (handleType = DMA_BUF_BIT_EXT, fd = dup(dmabuf_fd))
   ```
   - Must `dup()` the FD — Vulkan takes ownership and closes it

4. **Synchronize:**
   - Export sync file: `ioctl(dmabuf_fd, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, ...)` (kernel >= 5.19)
   - Import into Vulkan: `vkImportSemaphoreFdKHR()` with the sync FD
   - Use as wait semaphore in `vkQueueSubmit`
   - Older kernels: implicit sync works on Mesa/AMD drivers

5. **Layout transition:**
   - Pipeline barrier with `srcQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT`

**Blocker for v0.8.0:** Godot does NOT enable `VK_EXT_external_memory_dma_buf` or `VK_EXT_image_drm_format_modifier` in its VkDevice creation. We'd need either a custom Godot build or confirmation that these extensions are available. The CPU-copy path avoids this entirely.

---

## 4. PipeWire Audio Capture

### 4.1 Monitor Capture Approach

**New files:**
- `addons/nightfall-stream/src/audio/pipewire_audio.cpp`
- `addons/nightfall-stream/src/audio/pipewire_audio.h`

Capture desktop audio by connecting to the default audio sink's monitor using `PW_KEY_STREAM_CAPTURE_SINK = "true"`:

```cpp
struct pw_properties *props = pw_properties_new(
    PW_KEY_MEDIA_TYPE, "Audio",
    PW_KEY_MEDIA_CATEGORY, "Capture",
    PW_KEY_MEDIA_ROLE, "Music",
    PW_KEY_STREAM_CAPTURE_SINK, "true",   // Capture monitor output
    NULL);

struct pw_stream *stream = pw_stream_new_simple(
    pw_thread_loop_get_loop(loop),
    "nightfall-desktop-audio",
    props,
    &stream_events,
    user_data);

pw_stream_connect(stream,
    PW_DIRECTION_INPUT,        // Consumer/capture
    PW_ID_ANY,                 // Auto-connect to default sink
    PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
    params, n_params);
```

This captures "what you hear" — all audio playing through the default output — without requiring the user to change their audio routing.

### 4.2 Format Negotiation

Offer multiple audio formats with F32P as preferred:

```cpp
SPA_FORMAT_AUDIO_format,
SPA_POD_CHOICE_ENUM_Id(9,
    SPA_AUDIO_FORMAT_F32P,        // preferred (first = default)
    SPA_AUDIO_FORMAT_U8,
    SPA_AUDIO_FORMAT_S16_LE,
    SPA_AUDIO_FORMAT_S32_LE,
    SPA_AUDIO_FORMAT_F32_LE,
    SPA_AUDIO_FORMAT_U8P,
    SPA_AUDIO_FORMAT_S16P,
    SPA_AUDIO_FORMAT_S32P,
    SPA_AUDIO_FORMAT_F32P)
```

Default sample rate: 48000 Hz. Default channels: 2 (stereo).

### 4.3 Audio Processing (process callback)

```cpp
static void on_audio_process(void *data) {
    struct pw_buffer *b = pw_stream_dequeue_buffer(stream);
    if (!b) return;

    struct spa_buffer *buf = b->buffer;
    struct spa_data *d = &buf->datas[0];

    if (!d->data || d->chunk->size == 0) {
        pw_stream_queue_buffer(stream, b);
        return;
    }

    uint8_t *audio_data = (uint8_t *)d->data + d->chunk->offset;
    uint32_t audio_size = d->chunk->size;
    int32_t stride = d->chunk->stride;  // bytes per frame (channels * bps)

    // Push into ring buffer for Godot audio thread to consume
    audio_ring_buffer.write(audio_data, audio_size);

    pw_stream_queue_buffer(stream, b);  // Always requeue immediately
}
```

### 4.4 Audio Output to Godot

Route captured audio into Godot's audio system:

- Create an `AudioStreamGenerator` with matching sample rate (48000 Hz)
- Assign it to an `AudioStreamPlayer` or `AudioStreamPlayer3D`
- Each frame, push PCM samples from the ring buffer into `AudioStreamGeneratorPlayback::push_buffer()`
- Handle format conversion if PipeWire delivers a format other than F32 (Godot expects 32-bit float)
- For planar formats (F32P), interleave channels before pushing

### 4.5 Audio/Video Sync

Since video and audio come from different PipeWire streams:
- Both are driven by the same PipeWire daemon, so timestamps are in the same clock domain
- Use `spa_meta_header` timestamps on video frames and `SPA_IO_Position` on audio for correlation
- In practice, the slight desync should be imperceptible for VR — both are sub-millisecond from the compositor
- If drift is detected, drop or duplicate audio frames to resync

### 4.6 Shared PipeWire Thread

Both video and audio PipeWire streams can share the same `pw_thread_loop`:
- Use `pw_stream_new()` (not `pw_stream_new_simple`) with a shared `pw_core`
- This avoids two separate PipeWire threads and simplifies lifecycle management
- The D-Bus portal FD is only needed for the video ScreenCast stream; audio connects to the system PipeWire daemon directly

---

## 5. Build System Changes

### 5.1 CMake Changes

**File:** `addons/nightfall-stream/CMakeLists.txt`

Add Linux-only conditional dependencies:

```cmake
if(NIGHTFALL_PLATFORM_LINUX)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(PIPEWIRE IMPORTED_TARGET REQUIRED libpipewire-0.3)
    pkg_check_modules(LIBSYSTEMD IMPORTED_TARGET REQUIRED libsystemd)
    # libsystemd provides sd-bus for D-Bus portal communication
endif()
```

Link targets (Linux only):
```cmake
if(NIGHTFALL_PLATFORM_LINUX)
    target_link_libraries(${LIBNAME} PRIVATE
        PkgConfig::PIPEWIRE
        PkgConfig::LIBSYSTEMD
    )
endif()
```

Compile definitions:
```cmake
if(NIGHTFALL_PLATFORM_LINUX)
    target_compile_definitions(${LIBNAME} PRIVATE NIGHTFALL_HAS_PIPEWIRE)
endif()
```

### 5.2 vcpkg Changes

PipeWire and libsystemd are system libraries — they should NOT be built via vcpkg. Use `pkg_check_modules` to find them from the system. This matches how Avahi is already handled in the existing CMakeLists.txt.

### 5.3 Docker Build Changes

**File:** `Dockerfile.linux-build`

Add packages:
```
libpipewire-0.3-dev
libsystemd-dev
```

These are available in Ubuntu 22.04 (the current Docker base image).

### 5.4 Android Build — No Changes

All PipeWire/D-Bus code is guarded by `#ifdef NIGHTFALL_HAS_PIPEWIRE`. Android builds are completely unaffected.

---

## 6. GDScript Integration

### 6.1 Stream Manager Changes

**File:** `src/stream_manager.gd`

New flow when `local_capture_mode == true`:

1. `start_stream()`:
   - Detect localhost, set `local_capture_mode = true`
   - Call `_b()._set_local_capture_mode(true)` on the GDExtension
   - Set minimal Sunshine params (320x240@1fps)
   - Start the Sunshine connection (control-only, video discarded)
   - Call `_b()._start_pipewire_capture()` to begin PipeWire ScreenCast
   - Call `_b()._start_pipewire_audio()` to begin audio capture

2. `stop_stream()`:
   - Call `_b()._stop_pipewire_capture()` and `_b()._stop_pipewire_audio()`
   - Then stop the Sunshine connection normally

3. `bind_texture()`:
   - In local mode, the texture comes from PipeWire via the same TextureUploader
   - No changes needed — the GDExtension feeds frames into TextureUploader regardless of source

### 6.2 State Manager Changes

**File:** `src/state_manager.gd`

New config keys in `user://app_state.cfg`:

| Section | Key | Type | Default | Purpose |
|---------|-----|------|---------|---------|
| `local_capture` | `restore_token` | String | `""` | PipeWire ScreenCast restore token |
| `local_capture` | `auto_detect` | bool | `true` | Auto-detect localhost connections |

### 6.3 Signal Connections

New signals from GDExtension:
- `pipewire_capture_started()` — ScreenCast session established, frames incoming
- `pipewire_capture_stopped()` — ScreenCast session ended
- `pipewire_capture_error(String)` — ScreenCast failed (show in UI)
- `restore_token_updated(String)` — New token to persist
- `pipewire_audio_started()` — Audio capture active
- `pipewire_audio_stopped()` — Audio capture ended

---

## 7. Implementation Phases

### Phase 1: Sunshine Control-Only Connection (GDScript + C++ flag)

**Estimated effort:** Small

1. Add `_is_local_host()` detection in `stream_manager.gd`
2. Add `_set_local_capture_mode()` to GDExtension
3. Modify `start_stream()` to use minimal params when local
4. Suppress video watchdog in `stream_connection.cpp` when mode is active
5. Test: verify controllers still work with Sunshine when video is discarded

**Deliverable:** Sunshine control-only connection works, video frames silently dropped

### Phase 2: PipeWire ScreenCast Video Capture (C++ D-Bus + PipeWire)

**Estimated effort:** Large

1. Implement `dbus_portal.cpp` — sd-bus D-Bus client for ScreenCast portal
2. Implement `pipewire_capture.cpp` — PipeWire stream consumer
3. Implement restore token save/restore in `state_manager.gd`
4. Implement `dmabuf_importer.cpp` — mmap + TextureUploader path
5. Add CMake/Docker build changes for libpipewire and libsystemd
6. Test: verify raw desktop frames appear on screen_mesh in local mode

**Deliverable:** Desktop video captured via PipeWire, displayed in VR

### Phase 3: PipeWire Audio Capture (C++ PipeWire + GDScript)

**Estimated effort:** Medium

1. Implement `pipewire_audio.cpp` — PipeWire audio monitor capture
2. Implement ring buffer + AudioStreamGenerator bridge
3. Handle format conversion (F32P/S16 -> Godot float)
4. Test: verify desktop audio plays in VR alongside video

**Deliverable:** Desktop audio captured via PipeWire, played in VR

### Phase 4: Polish & Edge Cases

**Estimated effort:** Medium

1. Handle multi-monitor: if user has multiple displays, let them pick (or use restore token)
2. Handle compositor fallback: if DMA-BUF fails, fall back to MemFd/MemPtr
3. Handle portal cancellation: user dismisses the display picker
4. Handle PipeWire disconnection: compositor restart, screen configuration change
5. Handle format edge cases: BGRx/RGBx RGB formats need separate upload path
6. Add "Local Capture" toggle in settings UI (for manual override)
7. Add latency stats display for local capture mode
8. Test on KDE, GNOME, and wlroots compositors

**Deliverable:** Robust local capture mode ready for release

---

## 8. Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Compositor DMA-BUF incompatibility** | No frames received | Fall back to MemFd/MemPtr CPU-copy path; mmap always works |
| **Restore token rejected** | User must pick display each launch | Graceful fallback; only a minor annoyance on first launch per session |
| **Sunshine terminates connection** | No controller input | Keep-alive pings on ENet; test with minimal stream params |
| **mmap of tiled DMA-BUF fails** | Garbled frames | Validate with `DRM_FORMAT_MOD_LINEAR` first; skip vendor modifiers if mmap fails |
| **Audio/video drift** | Noticeable desync | Use PipeWire timestamps for correlation; implement audio frame drop/dup |
| **sd-bus not available** | No D-Bus portal access | libsystemd is universally available on modern Linux; add runtime check |
| **BGRx format not handled** | Wrong colors or crash | Implement RGB upload path in Phase 4; NV12/YUV420P work from Phase 2 |
| **Godot VkDevice missing extensions** | Zero-copy impossible | CPU-copy path is v0.8.0 default; zero-copy deferred to future release |
| **PipeWire not installed** | Feature unavailable | Runtime detection; fall back to normal Sunshine streaming with warning |

---

## 9. New File Summary

| File | Type | Purpose |
|------|------|---------|
| `src/video/pipewire_capture.cpp` | C++ | PipeWire ScreenCast session + stream consumer |
| `src/video/pipewire_capture.h` | C++ | Header for above |
| `src/video/dbus_portal.cpp` | C++ | D-Bus sd-bus client for xdg-desktop-portal ScreenCast |
| `src/video/dbus_portal.h` | C++ | Header for above |
| `src/video/dmabuf_importer.cpp` | C++ | DMA-BUF mmap -> TextureUploader bridge |
| `src/video/dmabuf_importer.h` | C++ | Header for above |
| `src/audio/pipewire_audio.cpp` | C++ | PipeWire audio monitor capture |
| `src/audio/pipewire_audio.h` | C++ | Header for above |

(All paths relative to `addons/nightfall-stream/`)

## 10. Modified File Summary

| File | Changes |
|------|---------|
| `src/stream_manager.gd` | Localhost detection, mode switch, minimal Sunshine params, PipeWire start/stop |
| `src/state_manager.gd` | Restore token persistence, local_capture config section |
| `src/ui_controller.gd` | "Local Capture" badge, error display |
| `addons/nightfall-stream/src/nightfall_stream.h` | New bound methods + signals |
| `addons/nightfall-stream/src/nightfall_stream.cpp` | `_set_local_capture_mode()`, PipeWire start/stop wrappers |
| `addons/nightfall-stream/src/video/stream_connection.cpp` | Video watchdog suppression in local mode |
| `addons/nightfall-stream/CMakeLists.txt` | PipeWire + libsystemd dependencies (Linux only) |
| `Dockerfile.linux-build` | Add `libpipewire-0.3-dev`, `libsystemd-dev` |
