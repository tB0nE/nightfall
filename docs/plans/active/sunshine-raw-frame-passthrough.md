# Sunshine Raw Frame Passthrough Patch Plan

> Status: Active proposal; requires coordinated Sunshine changes

## Goal
Add a "raw frame" encoder to Sunshine that streams uncompressed NV12 frames over the network (or localhost) instead of HEVC/H.264 encoding. This eliminates encode latency and generation loss on the first hop, critical for setups where Nightfall runs on the same machine as Sunshine (e.g., PCVR via WiVRn).

## Use Case
- User runs Sunshine + Nightfall on the same PC
- Nightfall receives raw NV12 frames over localhost — no HEVC decode needed
- WiVRn handles the single encode to the Quest
- Result: zero generation loss, zero encode latency on the host-to-client hop

## Architecture Overview

### Current Sunshine Pipeline
```
Desktop Capture (KMS/NVFBC/X11) → NV12 frames → HEVC/H.264 encode → RTP packets → Network → Client
```

### Proposed Pipeline
```
Desktop Capture (KMS/NVFBC/X11) → NV12 frames → Raw frame packaging → TCP/UDP → Network → Client
```

The "raw encoder" is really just a **passthrough** — it takes the captured NV12 frame, adds a lightweight header (frame number, resolution, timestamp), and sends it as-is over the network. No quantization, no DCT, no entropy coding.

## Implementation Plan

### Step 1: Fork and Build Sunshine
- Clone Sunshine from https://github.com/LizardByte/Sunshine
- Verify build works on the target platform
- Understand the encoder plugin architecture

### Step 2: Study Sunshine's Encoder Architecture
Key files to understand:
- `src/platform/common.h` — capture interface, NV12 frame format
- `src/video.h` / `src/video.cpp` — encoder base class, encoder selection
- `src/video/avcodec.h` / `avcodec.cpp` — existing HEVC/H.264 encoder implementation
- `src/video/nvenc.h` / `nvenc.cpp` — NVIDIA hardware encoder
- `src/video/vce.h` / `vce.cpp` — AMD hardware encoder
- `src/video/vaapi.h` / `vaapi.cpp` — VAAPI hardware encoder
- `src/stream.h` / `src/stream.cpp` — how encoded packets are sent to clients
- `src/input.h` — input handling (unchanged)

Key concepts:
- Sunshine captures frames as `platf::NV12` objects (already in GPU memory or DMA-BUF)
- Encoders implement `video::encoder_t` interface — `encode(frame)` returns encoded packets
- Encoded packets go through `stream::broadcast()` to send to connected clients
- The Moonlight protocol uses a custom packet format over ENet

### Step 3: Implement Raw Frame Encoder

Create `src/video/raw.h` and `src/video/raw.cpp`:

**Key design decisions:**
- The raw encoder receives NV12 frames and serializes them as-is
- Frame header: magic (4 bytes), frame_number (4 bytes), width (2 bytes), height (2 bytes), timestamp (8 bytes), y_size (4 bytes), uv_size (4 bytes)
- NV12 layout: Y plane (width × height bytes) followed by interleaved UV plane (width × height/2 bytes)
- Frame is sent as a single large packet (not split into NAL units)
- For localhost, send over existing ENet connection with RELIABLE+UNSEQUENCED flag

**The encoder class:**
```cpp
class raw_t : public encoder_t {
public:
    int encode(frame_t &frame) override;
    // ... 
};
```

**`encode()` implementation:**
1. Receive `platf::NV12` frame from capture
2. Map the frame's GPU memory to CPU-accessible pointers (or use existing mapped buffer)
3. Build header with frame metadata
4. Copy Y + UV planes into a contiguous buffer
5. Send as one packet via the existing stream infrastructure

**Important considerations:**
- NV12 frames are already in CPU-accessible memory after Sunshine's capture step (KMS gives DMA-BUF, which is mapped)
- For NVIDIA: NVFBC captures to system memory already; for AMD/Intel: KMS + mmap
- Avoid extra GPU→CPU copies — Sunshine's capture already produces CPU-accessible buffers
- Frame size at 1080p60: 1920×1080 × 1.5 = ~3.1 MB per frame, ~186 MB/s at 60fps
- Frame size at 4K60: 3840×2160 × 1.5 = ~12.5 MB per frame, ~746 MB/s at 60fps
- Loopback TCP can easily handle this; Wi-Fi 6E (~1.2 Gbps) can handle 1080p60

### Step 4: Add Encoder Selection

In `src/video.cpp` (or wherever encoder selection happens):
- Add `raw` as an encoder option alongside `nvenc`, `vaapi`, `avcodec`
- Add config option: `encoder = raw` in `sunshine.conf`
- When `raw` is selected, instantiate `raw_t` instead of `avcodec_t` / `nvenc_t`

### Step 5: Client-Side Reception (Nightfall)

In Nightfall's `stream_connection.cpp`:
- Detect raw frame format from the Moonlight session negotiation (codec ID)
- When receiving raw frames:
  1. Parse header (frame number, resolution, timestamp)
  2. Validate dimensions match expected stream size
  3. Copy Y plane into `rd_texture_buffers[0]`
  4. Copy UV plane into `rd_texture_buffers[1]`
  5. Call `perform_gpu_update()` to upload to GPU
- This is essentially what the current VAAPI decode path does AFTER decoding — we just skip the decode step

In `ffmpeg_decoder.cpp`:
- Add a "raw" codec family alongside H264, H265, AV1
- When raw is selected, skip FFmpeg entirely — just parse the raw frame header and copy planes

In `stream_manager.gd`:
- Add "raw" as a video format option in `supported_video_formats`
- The Moonlight protocol has a VIDEO_FORMAT field — need to check if there's an unused/custom value we can use, or if we need to extend the protocol

### Step 6: Protocol Considerations

The Moonlight protocol (moonlight-common-c) uses specific codec IDs:
- H.264 = 0x01
- HEVC = 0x02  
- AV1 = 0x04

Options:
1. **Use an unused/custom codec ID** (e.g., 0x08 or 0x10) — simplest, both sides need to agree
2. **Reuse HEVC ID but with a flag** — messy, could break compatibility
3. **Extend the protocol** — proper but requires moonlight-common-c changes

Recommendation: Use a custom codec ID (e.g., 0x80 for "raw"). Both Sunshine and Nightfall need to understand it. Other Moonlight clients will simply not support it (they'll reject the session).

### Step 7: Testing

1. Build patched Sunshine with `encoder = raw` in config
2. Run Sunshine + Nightfall on same machine
3. Connect Nightfall to localhost
4. Verify: no encode latency, no generation loss, clean frames
5. Compare with HEVC: measure latency difference (should be ~5-15ms savings)
6. Test at 1080p60, 1440p60, 4K60

### Step 8: Submit as Patch to Sunshine

Create a PR to LizardByte/Sunshine with:
- `src/video/raw.h` and `src/video/raw.cpp` — the raw encoder
- Config option for encoder selection
- Documentation for the new mode

Pitch: "Raw frame passthrough for LAN/localhost streaming where bandwidth is abundant and encode latency/quality loss is unacceptable. Useful for VR streaming setups where the client is on the same machine."

## Bandwidth Requirements

| Resolution | FPS | NV12 Size/Frame | Bandwidth |
|-----------|-----|-----------------|-----------|
| 1080p | 60 | 3.1 MB | 186 MB/s (1.5 Gbps) |
| 1440p | 60 | 5.6 MB | 333 MB/s (2.7 Gbps) |
| 4K | 60 | 12.4 MB | 746 MB/s (6.0 Gbps) |

- **localhost/loopback**: Unlimited, works for all resolutions
- **10GbE**: Works for 1080p60 and 1440p60
- **Wi-Fi 6E (1.2 Gbps)**: Works for 1080p60 only
- **1GbE**: Only 1080p30 or lower

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Large frames may exceed ENet packet limits | Use reliable stream channel; fragment if needed |
| NV12 frame CPU access may stall GPU | Sunshine already maps capture buffers to CPU |
| Breaks Moonlight protocol compatibility | Use custom codec ID; other clients simply won't support it |
| Security: raw frames could be intercepted | No worse than existing unencrypted stream; use VPN if concerned |
| Sunshine maintainers may reject PR | Frame it as an opt-in feature; disabled by default |

## Alternative: Shared Memory (Same Machine Only)

If both Sunshine and Nightfall are on the same machine, an even simpler approach:
- Sunshine writes NV12 frames to a shared memory region (shm_open + mmap)
- Nightfall reads from the same shared memory
- Zero network overhead, zero copies if GPU buffer is mapped

This avoids the network stack entirely but only works for same-machine scenarios. Could be a follow-up enhancement.
