# Encoding Selector Feature

## Overview
Add a UI toggle that lets the user select which video codec (H.264, HEVC, AV1, Raw) to use for streaming. The server's supported codecs are queried during connection; the client probes its own decode capabilities at runtime. Unsupported codecs are skipped in the cycle. The selected codec is persisted and applied on stream start/restart. **Default: HEVC.**

## Current Architecture
- `probe_video_format(0, false)` in `ffmpeg_decoder.cpp` auto-detects ALL working decoders and returns a bitmask (e.g., `H264|H265|AV1`)
- This bitmask is passed as `supportedVideoFormats` to moonlight-common-c via `STREAM_CONFIGURATION`
- moonlight-common-c intersects client mask with server's `serverCodecModeSupport` during RTSP negotiation and picks the "best" codec (prefers HEVC)
- `probe_video_format(codec_preference, ...)` already accepts a `codec_preference` parameter (0=auto, 1=H264, 2=H265, 3=AV1) but it's always called with 0
- Server's `serverCodecModeSupport` is already extracted from `/serverinfo` response in `computer_manager.cpp` and forwarded to GDScript
- The `CODEC_FAMILY_*` constants: H264=1, H265=2, AV1=3 (defined in `ffmpeg_decoder.cpp`)
- The `SCM_*` constants in Limelight.h map to server-side codec support bits

## Codec Values
| Index | Label | CODEC_FAMILY | VIDEO_FORMAT_MASK | SCM flag |
|-------|-------|-------------|-------------------|---------|
| 1 | H.264 | 1 | 0x000F | SCM_H264=0x01 |
| 2 | HEVC | 2 | 0x0F00 | SCM_HEVC=0x0100, SCM_HEVC_MAIN10=0x0200 |
| 3 | AV1 | 3 | 0xF000 | SCM_AV1_MAIN8=0x010000, SCM_AV1_MAIN10=0x020000 |
| 4 | Raw | 4 | 0x10000 | SCM_RAW_NV12=0x01000000 |

## Sunshine Raw Frame Protocol (from tB0nE/Sunshine:raw-frame-encoder)
- `VIDEO_FORMAT_RAW_NV12 = 0x10000` — bitmask in `supportedVideoFormats`
- `VIDEO_FORMAT_INDEX_RAW = 3` — index in videoFormat field (0=H264, 1=H265, 2=AV1, 3=RAW)
- `SCM_RAW_NV12 = 0x01000000` — server advertises raw support in `ServerCodecModeSupport`
- Raw frame header: 28 bytes, packed struct:
  ```
  magic[4] = "RAWF"
  frame_number: uint32
  width: uint16
  height: uint16
  timestamp_ns: int64
  y_size: uint32
  uv_size: uint32
  ```
- Followed by Y plane (y_size bytes) then interleaved UV plane (uv_size bytes) — standard NV12 layout
- Sunshine rejects standard Moonlight clients when raw encoder is active (RTSP 400)
- Sunshine only activates raw encoder when `encoder = raw` is set in `sunshine.conf`

## Implementation Plan

### Step 1: Define Raw codec constants in Limelight.h
**Files:** `addons/nightfall-stream/build/.../include/Limelight.h` (vcpkg installed copy)

Add to the video format definitions:
```c
#define VIDEO_FORMAT_RAW_NV12     0x10000
#define VIDEO_FORMAT_MASK_RAW     0x10000
```

Add to SCM definitions:
```c
#define SCM_RAW_NV12              0x01000000
```

Note: The actual Limelight.h is in the vcpkg_installed tree. We may need to patch it or define our own constants in a separate header that we control.

### Step 2: Add CODEC_FAMILY_RAW to decoder + raw decode path
**Files:** `ffmpeg_decoder.cpp`, `ffmpeg_decoder.h`, `stream_connection.cpp`, `stream_connection.h`

- Add `CODEC_FAMILY_RAW = 4` constant
- Add `VIDEO_FORMAT_MASK_RAW = 0x10000` constant
- In `probe_video_format()`: when `codec_preference == CODEC_FAMILY_RAW`, return `VIDEO_FORMAT_MASK_RAW` (always succeeds — raw decode is just memcpy, no FFmpeg needed)
- In `setup()`: when `videoFormat & VIDEO_FORMAT_MASK_RAW`, set `is_raw_mode = true`, skip FFmpeg decoder creation entirely
- In `_cb_decoder_setup()`: when raw mode, set pixel format to `AV_PIX_FMT_NV12` (raw frames are always NV12)
- Add raw frame parsing in the decode loop:
  1. Check packet for "RAWF" magic at offset 0
  2. Parse `raw_frame_header_t` (28 bytes)
  3. Copy Y plane to texture buffer[0], UV plane to texture buffer[1]
  4. Signal GPU update
- This completely bypasses FFmpeg — no `avcodec_send_packet`/`avcodec_receive_frame`

### Step 3: Expose probe results + server codec support to GDScript
**Files:** `nightfall_stream.cpp`, `nightfall_stream.h`, `stream_backend.gd`

Add `probe_all_video_formats() -> Dictionary`:
```python
{
  "h264": true/false,
  "hevc": true/false,
  "av1": true/false,
  "raw": true,  # always true — client-side raw decode is just memcpy
}
```
Call once at startup after backend init, cache results.

Expose `get_server_codec_mode_support() -> int` so GDScript can read the SCM bitmask after launch response.

### Step 4: Add codec preference state
**Files:** `main.gd`, `state_manager.gd`, `settings_controller.gd`

- `main.gd`: Add `var codec_preference: int = 2` (default HEVC) and `var codec_labels: Array = ["H.264", "HEVC", "AV1", "Raw"]`
- `main.gd`: Add `var _client_codec_support: Dictionary = {}` and `var _server_codec_support: Dictionary = {}`
- `state_manager.gd`: Save/restore `codec_preference`
- `settings_controller.gd`: Add `cycle_codec()` — cycles through available codecs only, skips unavailable ones

### Step 5: Compute codec availability
**Files:** `main.gd` or `settings_controller.gd`

After launch response populates `_server_codec_support` and startup probe populates `_client_codec_support`:
```python
func is_codec_available(idx: int) -> bool:
    match idx:
        1: return _client_codec_support.get("h264", false) and _server_codec_support.get("h264", false)
        2: return _client_codec_support.get("hevc", false) and _server_codec_support.get("hevc", false)
        3: return _client_codec_support.get("av1", false) and _server_codec_support.get("av1", false)
        4: return _server_codec_support.get("raw", false)  # client always supports raw
    return false
```

If no server info yet (pre-connect), show all codecs as available (let the stream fail if incompatible — same as today).

### Step 6: UI button for codec selection
**Files:** `ui_controller.gd`

Add `make_option_btn("Codec", "HEVC")` in row1.
When pressed, cycle: H.264 → HEVC → AV1 → Raw → H.264, **skipping unavailable codecs**.

If currently selected codec becomes unavailable after connecting to a server that doesn't support it, fall back to first available codec.

### Step 7: Apply codec preference on stream start
**Files:** `stream_manager.gd`

In `_on_v2_launch_response()`:
```python
var codec_pref = main.codec_preference  # 1=H264, 2=HEVC, 3=AV1, 4=Raw
if codec_pref == 4:
    stream_config["supported_video_formats"] = 0x10000  # VIDEO_FORMAT_MASK_RAW
else:
    stream_config["supported_video_formats"] = _b().probe_video_format(codec_pref, false)
```

When `codec_preference=2` (HEVC, the default), `probe_video_format(2, false)` returns only `VIDEO_FORMAT_MASK_H265`, forcing HEVC.

### Step 8: Stream restart on codec change
**Files:** `stream_manager.gd`, `settings_controller.gd`

If the user changes codec while streaming, trigger a debounced stream restart via `_restarting_stream`. Same pattern as resolution/fps/bitrate changes.

### Step 9: SCM bitmask → availability mapping
**Files:** `stream_manager.gd` or `main.gd`

```python
_server_codec_support = {
    "h264": (scm & 0x01) != 0,
    "hevc": (scm & 0x0300) != 0,
    "av1": (scm & 0x030000) != 0,
    "raw": (scm & 0x01000000) != 0,
}
```

### Step 10: Colorspace for raw frames
**Files:** `stream_connection.cpp`

In `_resolve_frame_colorspace()`: when `active_video_format_ & VIDEO_FORMAT_MASK_RAW`, raw frames are NV12 captured from desktop — use same logic as HEVC (BT.709 for HD). The raw encoder in Sunshine does BGR0→NV12 via sws, which uses the source colorspace. Desktop capture is typically sRGB → BT.709 for HD content.

## Execution Order
1. Define raw codec constants (Limelight.h patch or own header)
2. Add CODEC_FAMILY_RAW + raw decode path in C++ (bypasses FFmpeg)
3. Expose probe results + server SCM to GDScript
4. Add state variables, persistence, and default (HEVC)
5. Add UI button + cycling with availability skip
6. Wire codec preference into stream start
7. Add stream restart on codec change
8. SCM bitmask decoding
9. Test: H.264 on Quest, HEVC on Quest, Raw on Linux (same machine)

## Testing Plan
- **H.264 on Quest**: Force H.264, verify stream starts, verify BT.601 colorspace
- **HEVC on Quest**: Force HEVC (default), verify stream starts (matches current behavior)
- **AV1 on Quest**: AV1 decoder may not exist on Quest 3 — should be skipped in cycle
- **Raw on Linux**: Build patched Sunshine with `encoder = raw`, connect Nightfall on same machine, verify raw NV12 frames display correctly
- **Linux VAAPI HEVC**: Force HEVC, verify VAAPI decode works
- **Linux H.264**: Force H.264, verify SW decode works
- **Codec change while streaming**: Verify stream restarts with new codec
- **Server without raw support**: Verify Raw option skipped in cycle
- **Colorspace**: Verify H.264→BT.601, HEVC/AV1/Raw→BT.709 for HD content
