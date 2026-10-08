# Nightfall Meteor: host-side depth maps

> Status: Phases 1 to 3 built and in use on the Quest 3 since 2026-10-04;
> most of Phase 4 done (updated 2026-10-08). The default runtime is ncnn on
> Vulkan, with Video Depth Anything on TensorRT downloaded on request
> ([meteor-appimage.md](meteor-appimage.md)). Ships for Linux in the release
> after v0.7.11; Windows is [meteor-windows.md](meteor-windows.md).
> Exit gates not recorded yet: a 30-minute AI 3D run on host depth (Phase 2),
> the match rate above 95% at 60 and 120 fps (Phase 3), and the effect on
> game FPS (Phase 4).
> Decisions agreed 2026-10-03.
>
> Date: 2026-10-03
>
> Builds on: `meteor/` (the transparent proxy, branch `feat/nightfall-meteor`)
> and [nightfall-gateway-experiment.md](nightfall-gateway-experiment.md).
>
> Initial platform: Linux host with an NVIDIA GPU (RTX 3090, driver 615),
> Vibepollo, Quest 3 client.

## Goal

Generate the AI 3D depth map on the host GPU instead of the Quest, from the
exact frames Sunshine sends, and deliver it to the client tagged with the
video frame it belongs to, so the client can pair each displayed frame with
its own depth.

Wins if it works:

- A much larger model, at a much higher input size, than the Quest can run.
  ZipDepth fp32 at 672x384 is already exported
  (`tools/ZipDepth/onnx_export/zipdepth_base_672x384.onnx`), and the
  2026-10-03 resolution sweep showed aspect-preserving 672x384 or 896x512
  beats our squashed 384x384.
- The Quest stops running TFLite and capturing frames for depth. The GPU
  delegate's contention with Godot's renderer goes away (see the Quest 3 GPU
  limits memory note).
- Exact frame matching instead of the current age-based Depth Sync estimate.

## Decisions (2026-10-03)

1. **Meteor becomes an AI 3D mode, chosen automatically.** When the client
   finds a Meteor that offers depth, the AI 3D model list gains a "Meteor"
   entry and the client switches to it. When Meteor goes away, the client
   switches back to the model that was selected before. If the user picks
   another model while Meteor is available, that choice sticks for that host
   until they pick Meteor again.
2. **Up to 120 Hz.** Depth follows the stream rate up to 120 Hz. The tray icon
   gets two dropdowns (submenus): **Model** and **Rate** (30 / 60 / 72 / 90 /
   120 Hz / Match stream). Changing either applies live, without restarting
   the stream.
3. **NVIDIA only** for the first version (NVDEC + CUDA / TensorRT). Windows
   and other GPUs come later.
4. **Model: the widescreen EdgePad family** (2026-10-04). Meteor defaults to
   `zipdepth_wide_512x288.onnx` and offers `zipdepth_wide_672x384.onnx` as
   the higher-quality choice, both from the model researcher's selected
   checkpoint (`nightfall-temporal-zipdepth`,
   `reports/NIGHTFALL_WIDESCREEN_FAMILY_HANDOFF.md`) and built by
   `meteor/tools/make_host_model.py`. These replace the square 384x384
   interim (2026-10-03), which was chosen because the stock-weight
   rectangular models gave wrong depth. On a replayed 2560x1440 gameplay
   clip the frame-to-map median is about 3.3 ms for either at 120 Hz.
5. **Microphone passthrough goes into Meteor too.** It has its own plan:
   [meteor-microphone.md](meteor-microphone.md).
6. **Default runtime: ncnn on Vulkan; TensorRT becomes an optional
   Performance pack** (2026-10-05). The ONNX Runtime + CUDA + TensorRT stack
   is gigabytes; ncnn is a few MB and measured about 1 ms slower per frame.
   See "Install size and the GPU runtime".

## Progress (2026-10-03)

**Phase 0**
- Benchmark done (`meteor/tools/bench_depth.py`, ONNX Runtime 1.30, CUDA
  provider, RTX 3090, with the desktop and a stream running):

  | Model | Median | p95 | VRAM |
  |---|---|---|---|
  | zipdepth_base_672x384 | 2.46 ms | 2.96 ms | ~400 MB |
  | zipdepth_base_512x288 | 1.86 ms | 2.90 ms | ~400 MB |
  | zipdepth_base_384 | 1.81 ms | 2.43 ms | ~400 MB |

  The 672x384 model is good for over 300 Hz, so TensorRT isn't needed yet.
  There is no 896x512 export, and making one means touching the ZipDepth
  tooling, which another agent is editing; skipped.
- `--dump-video` is built, along with the frame reassembly
  (`meteor/src/video_tap.rs`) and its loss counters, which are logged every
  10 s. **Not yet checked against a real stream:** that needs a Nightfall
  session through Meteor.

**Phase 1** (built; checked offline with `--replay` on an NVENC HEVC clip)
- The pieces:
  - NVDEC decoding through the driver (`meteor/src/nvdec.rs`, see below);
  - ONNX Runtime loaded at run time (`ort`, load-dynamic, CUDA libraries
    preloaded from the pip packages);
  - the Java post-processing, ported;
  - the newest-frame-wins engine;
  - tray toggle, Model and Rate submenus, and readout;
  - `--save-depth` PNG snapshots.
- Rust output matches a Python reference within 1 grey level.
- **Decoder.** The first version used an `ffmpeg` child process, which gave
  24.7 ms from frame in to map out at 60 fps. ffmpeg's command-line demuxing
  holds every frame until the next one arrives (measured at 1 frame interval
  plus about 3.5 ms, for H.264 and HEVC alike).
- It was replaced the same day by direct NVDEC:
  - `libcuda` and `libnvcuvid` are loaded with dlopen;
  - the struct layouts are checked against nv-codec-headers by a C program
    and by unit tests;
  - frames go in with `CUVID_PKT_ENDOFPICTURE` and display delay 0, so each
    one is decoded inside the same call;
  - NVDEC scales to the model size while decoding;
  - the frame number travels through as the timestamp.
- Frame in to depth map out, after warm-up:

  | Rate | Median | p95 | Decode | Model |
  |---|---|---|---|---|
  | 72 fps | 6.3 ms | 12.1 ms | 2-3.5 ms | about 2 ms |
  | 120 fps | 5.4 ms | 7.0 ms | | |

- NVDEC's colours match ffmpeg's decode within about 2 levels.
- **Zero-copy frames (Phase 4 item, done early).** A CUDA kernel
  (`meteor/kernels/nv12_to_tensor.cu`, compiled to PTX with NVRTC) converts
  NVDEC's NV12 straight into the model's input tensor in GPU memory. ONNX
  Runtime reads it in place, through a tensor that wraps the raw device
  pointer. The output is identical to the CPU path. Frame in to depth map
  out, median (p95):

  | Rate | GPU path | CPU path |
  |---|---|---|
  | 72 fps | 3.4-3.5 ms (5.7-7.1) | 6.0-6.4 ms |
  | 120 fps | 3.4-3.6 ms (5.1-6.2) | 4.9-5.6 ms |

  The decode step dropped from 2-3 ms to 0.8 ms.
- **TensorRT fp16 (Phase 4 item, done early).**
  - ZipDepth 384 runs in 0.85 ms, against 1.8 ms on CUDA.
  - Accuracy against fp32 after normalising: 0.4 grey levels on average,
    3 at most.
  - Meteor starts on CUDA, builds the engine in the background (90 s the
    first time per model and GPU, then cached and loaded in 0.4 s) and
    switches over.
  - It needs `tensorrt-cu13<11`, because ONNX Runtime 1.30 links TensorRT
    10.
  - Frame in to depth map out is now **3.0-3.2 ms median at 72 fps and
    2.8-3.0 ms at 120 fps**.
- **GPU post-processing (done).** The post-processing is now four CUDA
  kernels (`meteor/kernels/postprocess.cu`): min/max, a 512-bin histogram,
  the percentile range with its smoothing, and stretch, smooth and convert
  to 8-bit.
  - They run on the model's output while it's still on the GPU (ONNX Runtime
    IoBinding, with a device output buffer). Only the 147 KB 8-bit map comes
    back.
  - They're built without fused multiply-add. A unit test feeds identical
    frames and timestamps through both versions and requires byte-identical
    output over eight frames, which covers the smoothing.
  - Post-processing time: 1.07 ms down to 0.11 ms. The model also gets
    faster without the output copy (1.00 to 0.84 ms).
- **Current total: 1.8 ms median, about 3 ms p95, frame in to depth map
  out.** The stages are decode 0.82 ms, handoff 0.01 ms, model 0.84 ms and
  post-processing 0.11 ms. The thread handoff was measured too, and is
  negligible.
- AV1 isn't tested yet: the 3090 can't encode AV1 to make a test clip.
- Not yet done: the exit gate needs real game frames. That means
  `--save-depth` during a real session, compared with on-device ZipDepth.

**First real session (2026-10-04).** A Quest 3 stream through Meteor, 1440p
HEVC at 72 fps, about 62,000 frames: 0 incomplete, 0 packets dropped. NVDEC
decoded the real stream, and the saved maps look plausible.

**Phase 2** (built 2026-10-04; tested against `--replay` of a recorded
session, not yet on the Quest)
- **Meteor:** `src/depth_server.rs` on TCP 47901. A 32-byte header (frame
  number, epoch, size, Meteor's frame-to-map time) and a zstd level 1
  payload. A real 384x384 map averages 44 KB (147 KB raw), about 25 Mbit/s
  at 72 Hz. Discovery advertises `depth` only while host depth is on and a
  model is loaded. The model only runs while a client is connected;
  decoding continues regardless, because the decoder can only restart on a
  keyframe.
- **Client:** `src/meteor_depth.gd`, a GDScript receiver (StreamPeerTCP,
  Godot's built-in zstd), polled once per rendered frame; it keeps only the
  newest map. The native receiver in the design below is deferred to
  Phase 3, which needs the decoder's frame numbers anyway. On the PC, a poll
  averages 0.28 ms including decompression.
- **Switching:** "Meteor (<model>)" comes first in the AI 3D Model cycle
  while Meteor offers depth, and is chosen automatically unless the user
  picked an on-device model for that host (`ai_3d_meteor_declined`). It
  isn't an `ai_3d_models` entry, so no saved index shifts. While Meteor's
  maps arrive, the client stops capturing frames for depth and submitting
  them, so the Quest's model never runs. If no map arrives for 1 s (3 s
  after connecting), on-device depth resumes until maps come back.
- **Guide texture.** The native renderer only applies depth when the
  on-device capture's guide texture exists (`has_depth` in
  `fast_xr_renderer_android.cpp`). The first Quest test showed no 3D for
  that reason, although maps arrived at 57/s. While Meteor is in use the
  client now still captures a guide frame twice a second and discards it.
  The production stage (Full-Linear) doesn't read the guide's pixels; a
  stage that does (Guided) would see a stale guide. Replaced in Phase 3 by
  the renderer fix below.
- **Not yet:** Depth Sync uses an age of 0 for host maps, the stats overlay
  doesn't show host depth, and only the logs (`[METEOR-DEPTH]`, once a
  second) report rate, bandwidth and Meteor's latency.

**Phase 3** (built 2026-10-04; in use on the Quest since, but its match-rate gate isn't recorded)
- **Which frame is on screen.** `stream_connection.cpp` records each frame's
  decoder PTS (its enqueue time) against its Moonlight frame number, and
  `_record_rendered_frame()`, which every decode path calls, looks the
  rendered frame up. `get_presented_frame_number()` exposes it.
- **Receiver thread.** `meteor_depth.gd` now reads, parses and decompresses
  on a worker thread and keeps the last 12 maps. The main thread only picks
  one: 0.013 ms a frame, measured against a live 120 Hz stream, down from
  0.28 ms.
- **Matching.** The client shows the map for the frame on screen, or the
  newest one before it, never one from a later frame. With Depth Sync on,
  the colour delay stays at 1 frame and the map for that delayed frame is
  shown; it moves to 2 frames only if over 10% of frames miss their map in a
  2-second window, and back once 98% would match at 1. Each change repeats
  or skips one video frame, so it changes rarely.
- **Renderer.** `fast_xr_renderer_android.cpp` applies depth without a guide
  texture, resizing linearly when there's none; host depth passes no guide.
  The twice-a-second guide capture from Phase 2 is gone.
- **Stats.** `[METEOR-DEPTH]` logs, once a second, the presented frame,
  the newest map's frame, the exact-match rate, how many frames showed a
  map 1, 2 or 3+ frames old, and the Depth Sync delay. The stats overlay
  doesn't show these yet.

## Where this sits next to the Gateway plan

The Gateway plan terminates both sessions. It connects upstream as its own
Moonlight client, and speaks a new Nightfall protocol to the headset. That is
the most robust design, but it means rebuilding pairing, the downstream
transport, input, audio and recovery before any depth reaches the headset.

Meteor is already in the stream path as a transparent proxy, so it can
**tap** the video it forwards instead:

```text
Sunshine ──UDP video──► Meteor ──(unchanged, forwarded first)──► Quest decoder
                          │
                          └─ copy ─► reassemble ─► NVDEC ─► ZipDepth ─┐
                                                                     │
Quest depth cache ◄──── depth side channel (frame number + map) ◄────┘
```

The video path stays byte-identical. Depth is extra. If anything on the depth
side fails, the stream doesn't notice and the client falls back to on-device
depth.

This covers Gateway phases 2-4 (duplicate decode, synchronized depth, bounded
sync) without phase 1 (the relay rewrite). If the tap's limits below become
real problems, that's the signal to move to the terminating gateway; the
depth pipeline and side channel carry over unchanged.

## Facts this plan relies on (checked 2026-10-03)

- **Frame identity already exists.** Each video packet carries
  `NV_VIDEO_PACKET.frameIndex` after the 12-byte RTP header.
  moonlight-common-c passes that same number to the client as
  `decodeUnit->frameNumber` (`VideoDepacketizer.c:486`). Meteor and the client
  can therefore both name a frame without adding anything to the stream.
- **The client can follow a frame through the decoder.** `stream_connection.cpp`
  queues `frame_number` and `presentation_time_us` per decode unit, and
  `mediacodec_native.cpp` passes that PTS into `AMediaCodec_queueInputBuffer`.
  MediaCodec returns it on the output buffer, so a small PTS-to-frame map
  tells us which frame is on screen.
- **Video through Meteor is unencrypted by default.** Sunshine picks the
  encryption mode by peer address (`network.cpp:135`). Through Meteor the peer
  is `127.0.0.1`, which counts as PC/LAN, and `lan_encryption_mode` defaults
  to never. If a user turns LAN encryption on, Meteor can't read the video; it
  can tell from `x-ss-general.encryptionEnabled` in the client's RTSP
  ANNOUNCE, and reports "no host depth".
- **Meteor already sees the RTSP ANNOUNCE in plain text.** It carries the codec
  (`x-nv-vqos[0].bitStreamFormat`), resolution and FEC settings, so Meteor
  doesn't need to guess the stream format.
- **The client's depth input is one narrow seam.** `depth_estimator.gd` reads
  an L8 byte array from `stream_backend.get_depth_map()`, then uploads it to
  `depth_texture`. The warp shaders and native XR renderer only see that
  texture. Host depth can enter through the same call.
- **Depth Sync is a 1-2 frame colour delay ring** in the native XR renderer
  (`set_depth_sync(enabled, delay_frames)`). The delay is currently estimated
  from depth age (`native_xr_renderer.gd: depth_sync_delay_frames`). With
  frame numbers it can be exact.
- **The host has what it needs.** (Superseded: Meteor now calls NVDEC
  directly; see Progress.) The system ffmpeg has the `cuda` hwaccel
  (NVDEC), and the GPU is an RTX 3090 with 24 GB.

## Install size and the GPU runtime (2026-10-05)

Meteor itself is small; the GPU runtime is not. Measured on the
development machine:

| Part | Size |
| --- | --- |
| `nightfall-meteor` binary | 6 MB |
| One model (`zipdepth_wide_512x288.onnx`) | 25 MB |
| TensorRT engine cache, built on first run | about 50 MB |
| ONNX Runtime + CUDA + cuDNN + TensorRT (`target/bench-venv`) | 6.7 GB |

Most of the 6.7 GB is never used: TensorRT ships a "builder resource"
library per GPU generation (sm75 to sm120, 116 to 454 MB each, plus Windows
copies inside the Linux wheel), and the CUDA wheels include cuFFT, cuRAND,
NVRTC and nvJitLink, which Meteor doesn't load.

### Default: ncnn on Vulkan

ncnn (BSD licence, a few MB) runs the same models through Vulkan, needs
nothing but the GPU driver, and isn't tied to NVIDIA (decoding still is,
through NVDEC). Measured on the RTX 3090 with the ncnn 1.0.20260526 Python
wheel, fp16, including the host upload and download:

| Model | Back to back | Paced at 120 Hz | TensorRT (replay, 120 Hz) |
| --- | --- | --- | --- |
| 512x288 | median 2.05 ms, p95 2.6 | median 2.5 ms, p95 7.2 | 1.6 ms |
| 672x384 | median 2.53 ms, p95 3.1 | median 4.8 ms, p95 5.3 | 1.5 ms |

- Output matches ONNX Runtime with correlation 0.99984 (512) and 0.99992
  (672) in fp16; fp32 reaches 0.99998 but costs about 1 ms more.
- The paced runs are pessimistic: with no game running, the GPU drops to
  idle clocks (210 MHz) between frames. Under a game the clocks stay up.
  Measure it beside a game before relying on either number.
- Conversion: `pnnx model.onnx inputshape=[1,3,288,512] fp16=1`. ncnn has no
  `DepthToSpace` layer, so the ncnn models end at the packed 4-channel output
  and Meteor's CUDA post-processing unpacks the 2x2 blocks (channel order as
  in `make_host_model.py`) and applies the ReLU.
- The reduced frame lives in CUDA memory. Copying it to Vulkan through the
  host costs about 0.3 ms at 512x288; CUDA-Vulkan external memory sharing
  avoids even that.
- Install: binary, ncnn, and fp16 models (12 MB each), about 35 MB in all.

### Optional: the Performance pack (TensorRT)

For users who want the lowest latency, the tray offers a download of a
trimmed TensorRT runtime. Meteor keeps running on ncnn while it downloads,
then switches live, as it already does when switching models. What it needs:

| Part | Size |
| --- | --- |
| `libnvinfer` | 663 MB |
| Builder resource for the detected GPU only | 116 to 454 MB (RTX 3090, sm86: 176 MB) |
| `libnvonnxparser` | 5 MB |
| ONNX Runtime core and TensorRT provider | 30 MB |
| `libcudart` | about 1 MB |

About 0.9 to 1.2 GB depending on the GPU, before compression. Left out:
ONNX Runtime's CUDA provider (272 MB), cuDNN and cuBLAS/cuBLASLt (about
1.5 GB), cuFFT, cuRAND, NVRTC, nvJitLink and `libnvinfer_plugin` (about
0.6 GB). TensorRT 10 doesn't need cuDNN or cuBLAS by default, and the model
runs entirely in TensorRT; leaving out the CUDA provider still needs testing
(see "Open questions").

A further cut: build the engine once with the full builder, then run it on
TensorRT's lean runtime and delete the builder. That shrinks the installed
size but not the download, and the engine has to be rebuilt (and the
builder fetched again) when the GPU or driver changes. The pip wheels don't
include the lean runtime, so trying it needs NVIDIA's full TensorRT
download.

## Design

### 1. The tap (Meteor)

- After forwarding each video UDP packet to the client, Meteor copies it into
  a bounded channel. Forwarding never waits on the tap. When the channel is
  full, packets are dropped and the frame is marked incomplete.
- Reassembly, a small Rust port of common-c's `RtpVideoQueue` and
  depacketizer logic:
  - Group packets by `frameIndex` and order them by `streamPacketIndex`.
  - Keep only data shards (FEC index < data shard count from `fecInfo`).
  - Use the start and end-of-frame flags, and strip the frame header Sunshine
    puts in the first packet, mirroring common-c.
- Loss: Sunshine to Meteor is loopback, so loss should be essentially zero,
  given a large receive buffer (8 MB) on Meteor's upstream socket. Count
  incomplete frames from day one.
- Meteor can't request an IDR: the control channel is encrypted with keys only
  the client has. If a tapped frame is lost, the decoder conceals the damage,
  depth is marked degraded, and the next keyframe clears it. If the counters
  show this matters, add FEC recovery by binding Sunshine's own Reed-Solomon
  library (nanors), so the parity matches.
- Codec support: H.264, HEVC and AV1. PyroWave isn't supported; there's no
  host depth for it.

### 2. Decode and inference (Meteor)

- ffmpeg (via `ffmpeg-next` or `rsmpeg`) does the NVDEC decode, then
  `scale_cuda` takes it to the model input size with the aspect ratio kept
  (672x384 for 16:9). Prototype: download the small RGB frame (about 0.8 MB)
  and hand it to ONNX Runtime. Final: keep it on the GPU (ORT IoBinding on
  CUDA memory) once the simple path is measured.
- ONNX Runtime (`ort` crate) with the CUDA execution provider first, and
  TensorRT fp16 once it works.
  - Start with `zipdepth_base_384.onnx` (Decision 4).
  - Make the model a setting in `meteor.toml`, and report it to the client.
- Post-processing must match what the client does today, so a host map looks
  like a local one: normalization, range tracking, and the per-model temporal
  smoothing (`depthTauSeconds` / `rangeTauSeconds` in `DepthEstimator.java`).
  Port that logic and keep a shared test vector.
- Rate: run on every frame up to the tray's Rate setting (Match stream by
  default, up to 120 Hz). When busy, skip frames; never queue them. The tray
  shows the rate actually achieved next to the setting.
- Model: the tray's Model submenu lists the ONNX files in Meteor's models
  folder. Switching loads the new model in the background and swaps it in
  between frames. Each depth message names the model it came from.
- Watch out: inference shares CUDA cores with the game being streamed. NVENC
  and NVDEC are separate engines, but the model isn't. Measure the game's FPS
  with host depth on and off, and add a "lower depth rate while the GPU is
  busy" option if needed.

### 3. Depth side channel

Encrypted since 2026-10-08 (transport version 2, `meteor/src/depth_server.rs`):
the client sends `NFDK` and a fresh X25519 public key on connecting, and each
map is sealed with AES-256-GCM under a key derived from it and Meteor's key
(`meteor/src/crypto.rs`), the header authenticated and the message count as
the nonce. The client decrypts in nightfall-stream (`MeteorChannelCipher`).
The design below describes version 1.

- Discovery reply gains `"depth": {"port": 47901, "formats": ["L8"],
  "width": .., "height": .., "max_hz": .., "model": ".."}`. It's optional, so
  older clients ignore it. Bump `protocol` only if the existing fields change
  meaning.
- Transport v1 is TCP to port 47901, opened by the client after the stream
  starts. Meteor pairs it with the video flow from the same client IP.
  - Reliable and ordered keeps v1 simple.
  - Head-of-line stalls are limited by Meteor keeping only the newest
    unsent map. If a map is still being written when the next one is ready,
    the older one is dropped.
  - Move to UDP or QUIC datagrams only if Wi-Fi measurements show stalls.
- Message: a fixed header followed by the payload.
  - Header: magic, version, epoch, `frame_number`, RTP timestamp, width,
    height, format, compression, model id, and decode/inference/send
    timestamps.
  - Payload: the map, zstd level 1.
- Epoch: it increments whenever the video flow reopens or `frameIndex` jumps
  backwards (a new stream). The client drops maps from an old epoch.
- Size and bandwidth: 672x384 L8 is 258 KB, about 124 Mbit/s at 60 Hz raw
  (248 Mbit/s at 120 Hz), which is too much on top of the video over Wi-Fi.
  - Send 336x192 (64 KB, about 31 Mbit/s at 60 Hz or 62 Mbit/s at 120 Hz raw,
    before zstd), upscaled by the client's existing upsample pass.
  - Measure what zstd actually achieves.
  - Later option: encode depth as low-bitrate grayscale video with NVENC.

### 4. Client: receive, match, display

- **Native receiver.** A `HostDepthReceiver` thread in nightfall-stream:
  - connects to the depth port once the stream is up;
  - decompresses each map;
  - keeps a ring of the last 8 maps keyed by frame number;
  - tracks stats: arrival lag in frames, misses and drops.
- **Which frame is on screen.** Record `presentationTimeUs -> frameNumber`
  when queuing decode units, and look it up when MediaCodec releases each
  output buffer. Expose `get_presented_frame_number()`.
- **Depth source.**
  - When Meteor advertises depth and the receiver is connected,
    `depth_estimator.gd` takes maps from the receiver instead of
    `get_depth_map()`, and skips local capture and inference entirely.
  - When the receiver drops out, it switches back to on-device depth.
- **Matching policies.**
  1. No wait (default): use the newest map at or before the presented frame.
     Never use a map from a *newer* frame.
  2. Depth Sync: set the colour delay ring to `presented - depth_frame`
     (clamped to 0-2), so the displayed frame and its depth match exactly.
     The ring already exists; only the delay calculation changes.
- **UI.** A "Meteor" entry in the AI 3D model list (Decision 1).
  - It's appended to `ai_3d_models` with a `meteor` flag instead of a Java
    index, so saved model indices don't shift.
  - It's added to the model cycle only while Meteor offers depth.
  - The model button shows Meteor's current model and rate, for example
    "Meteor (ZipDepth-672)".
  - The stats overlay shows host inference time, depth lag in frames, and
    exact-match rate.

One reason to expect good sync: Meteor gets each packet before the client
does, and starts decoding while the same packets are still crossing Wi-Fi and
going through the Quest's decoder. Host decode plus inference may well finish
before the Quest displays the frame. That has to be measured, not assumed:
log the distribution of `presented - depth_frame`.

## Phases

### Phase 0: measure (no client changes)

1. Benchmark `zipdepth_base_672x384.onnx` and the 896x512 shape with ONNX
   Runtime CUDA and TensorRT fp16 on the 3090: latency at batch 1, and VRAM.
2. Add a `--dump-video <file>` debug flag to Meteor. It writes the reassembled
   elementary stream during a real Nightfall session. Check that it plays
   cleanly with `ffplay`, which proves reassembly.
3. Log tapped-frame loss over a 30-minute session.

Exit gate:
- the dumped stream decodes cleanly;
- loopback loss is effectively zero;
- inference is fast enough for at least 30 Hz at 672x384.

### Phase 1: depth on the host

Add the decode and inference worker to Meteor, plus a tray readout (depth fps,
decode and inference ms, incomplete frames) and a debug option that saves
every Nth map as a PNG next to the frame it came from.

Includes the tray's Model and Rate submenus.

Exit gate: the saved maps match the frames and look at least as good as
on-device ZipDepth.

### Phase 2: deliver it

Build the depth port, the discovery field and the client receiver. Add the
"Meteor" AI 3D mode with its automatic switch, display host maps with the
no-wait policy, and switch back to the previous model when the receiver
drops.

Exit gate: an AI 3D stream runs on host depth for 30 minutes, the Quest's
TFLite stays idle, and the video is unaffected with host depth on or off.

### Phase 3: sync

Build the PTS-to-frame map, exact matching, and the Depth Sync integration.
Add stats for lag and match rate.

Exit gate: the lag distribution is known, and with Depth Sync on, the
displayed depth matches its frame in more than 95% of frames at 60 and
120 fps.

### Phase 4: polish

- Choose sizes and compression, and check 120 Hz on Wi-Fi.
- ~~Make the TensorRT and zero-copy CUDA paths the default.~~ Done
  2026-10-03.
- ~~Keep frames on the GPU from NVDEC to the model.~~ Done 2026-10-03 (see
  Progress). The model output still comes back to the CPU for
  post-processing (590 KB). Moving post-processing to the GPU is possible
  but small.
- Measure the impact on game FPS, with both ncnn and TensorRT.
- Switch the default runtime to ncnn on Vulkan (Decision 6): convert the
  models with pnnx, unpack the 2x2 output in the CUDA post-processing, and
  move the reduced frame from CUDA to Vulkan (through the host first, then
  external memory sharing).
- Build the Performance pack: the trimmed TensorRT file list for the
  detected GPU, a background download from the tray, and a live switch from
  ncnn once it's ready.
- Port to Windows: see [meteor-windows.md](meteor-windows.md). NVDEC and
  CUDA work there too, so NVIDIA hosts keep this pipeline; D3D11VA and
  DirectML would only matter for other GPUs.
- Add a Windows tray icon (Meteor currently has none on Windows).

## Risks

| Risk | Mitigation |
| --- | --- |
| A tapped frame is lost and Meteor's decoder stays corrupt until the next IDR | Large socket buffer; count losses in Phase 0; FEC via nanors if needed; the depth map is marked degraded rather than the stream being touched |
| Depth adds too much Wi-Fi traffic | 336x192, zstd, rate cap, and later NVENC grayscale video |
| Inference slows the game | Rate cap, fp16 (ncnn or TensorRT), and lowering the depth rate while the GPU is busy |
| ncnn falls behind under a game's GPU load | Measure beside a game; the tray offers the Performance pack; lower the depth rate |
| Host maps look different from local ones | Port the Java post-processing and share test vectors |
| Encrypted video (LAN encryption on) | Detect it from ANNOUNCE and report no host depth; the client uses on-device depth |
| HDR / 10-bit streams | Decode works; the model input needs a PQ-to-SDR conversion before inference. Defer it and flag HDR streams as unsupported at first |
| Stale or mismatched maps after a reconnect or resolution change | Epoch per stream; the client flushes its ring on stream start |

## Open questions

- Does ONNX Runtime's TensorRT provider run this model without the CUDA
  provider registered as a fallback? If so, the Performance pack drops the
  CUDA provider, cuDNN and cuBLAS (about 1.8 GB). Test: remove them from a
  copy of the runtime and run the replay benchmark.
- Which of these NVIDIA files may be redistributed (TensorRT and CUDA
  licences), and from where should Meteor download them?
- How much do the pack's files shrink when compressed for download?

- At 120 Hz, is the depth bandwidth acceptable on Wi-Fi, or should the
  client ask Meteor for a smaller map when it's on Wi-Fi rather than USB
  Link? Phase 4 answers this with measurements.
