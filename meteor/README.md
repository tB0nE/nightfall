# Nightfall Meteor

A companion app for the PC running Sunshine (or Apollo, Vibepollo, Polaris).
It sits in the system tray. When the Nightfall client connects to that PC, it
first asks Meteor which ports to use, and if Meteor answers, the stream goes
through Meteor instead of straight to Sunshine.

The goal is for Meteor to generate depth maps on the host GPU and send them
to the client (`docs/plans/active/meteor-host-depth.md`), and to give the PC
a microphone fed from the headset (`docs/plans/active/meteor-microphone.md`).

Status:
- **Proxy:** works. Everything is forwarded.
- **Host depth (Phase 2):** Meteor decodes the video it forwards, runs the
  depth model and sends each map to the headset on its depth port, where it
  appears as the "Meteor" AI 3D model. Exact frame matching is Phase 3.
- **Microphone (Phase 1):** the "Nightfall Microphone" device and the UDP
  receiver work. The headset doesn't send audio yet (Phase 2).

## Running

```
cd meteor
cargo run --release            # tray icon
cargo run --release -- --no-tray
```

`--help` lists the debug options (`--dump-video`, `--save-depth`, `--replay`,
`--no-depth`, `--no-mic`). Set `RUST_LOG=debug` for per-connection logging. The tray uses
StatusNotifierItem, so it shows on KDE, and on GNOME with the AppIndicator
extension. Windows and macOS run without a tray icon for now.

## How the client finds it

Before each launch, Nightfall sends `GET http://<host>:47900/meteor`. Meteor
replies with its version, protocol, and port map, for example:

```json
{"service":"nightfall-meteor","protocol":1,"mode":"proxy",
 "sunshine":{"https":47984,"http":47989,"rtsp":48010,"video":47998,...},
 "ports":{"https":48984,"http":48989,"rtsp":49010,"video":48998,...}}
```

The client uses Meteor only when `sunshine.https` matches the host's saved
HTTPS port, so a Meteor in front of a different Sunshine instance on the same
PC is ignored. If a launch through Meteor fails, the client retries once
straight to Sunshine.

## What it forwards

Meteor listens on every Sunshine port plus `port_offset` (1000 by default)
and forwards to Sunshine on `127.0.0.1`:

| Channel | Protocol | Sunshine | Meteor |
|---|---|---|---|
| HTTPS | TCP | 47984 | 48984 |
| HTTP | TCP | 47989 | 48989 |
| RTSP | TCP | 48010 | 49010 |
| Video | UDP | 47998 | 48998 |
| Control | UDP | 47999 | 48999 |
| Audio | UDP | 48000 | 49000 |
| Mic | UDP | 48002 | 49002 |

- HTTPS is passed through untouched, so TLS stays end to end between the
  client and Sunshine, and pairing is unaffected.
- The client points the launch request at Meteor's HTTPS port, and the RTSP
  session URL at Meteor's RTSP port.
- Sunshine's RTSP SETUP replies name its UDP ports
  (`Transport: server_port=47998`); Meteor rewrites them to its own ports so
  the client sends UDP traffic through Meteor too.
- Each client address gets its own upstream UDP socket, closed after 30
  seconds of silence.

Sunshine sees every client as `127.0.0.1`.

Limitation: encrypted RTSP (`rtspenc://`, used when Sunshine's encryption
mode requires it) can't be rewritten. HTTPS and RTSP still go through Meteor,
but video and audio then go straight to Sunshine. The client logs this.

## Host depth

Meteor copies each forwarded video packet to a tap, after forwarding it. The
tap rebuilds whole frames (`src/video_tap.rs`, a port of moonlight-common-c's
reassembly, keeping only the data shards). Each frame then goes through:

1. **Decode:** NVDEC, called directly through the NVIDIA driver
   (`src/nvdec.rs`), decodes the frame as soon as it's complete and scales it
   to the model's input size in the same step. A small CUDA kernel
   (`kernels/nv12_to_tensor.cu`) then writes the model's input tensor
   directly in GPU memory, and ONNX Runtime reads it in place, so the frame
   never passes through the CPU. Each frame stays tagged with its frame
   number. `--cpu-frames` switches to converting on the CPU, for
   comparison.
2. **Model:** ONNX Runtime runs the depth model (`src/onnx.rs`). It starts
   on CUDA within a second, builds a TensorRT fp16 engine in the background,
   and switches to it. The first build takes about 90 s per model and GPU;
   after that the engine is cached in `~/.cache/nightfall-meteor/tensorrt`
   and loads in about 0.4 s. Set `tensorrt = false`, or pass
   `--no-tensorrt`, to stay on CUDA.
3. **Post-processing:** ported from the Quest's `DepthEstimator.java`, so a
   host map matches an on-device one. It runs as CUDA kernels on the model's
   output while it's still on the GPU (`kernels/postprocess.cu`,
   `src/gpu_post.rs`), and only the finished 8-bit map is copied back. The
   CPU version (`src/postprocess.rs`) gives byte-identical results, which a
   unit test checks; it's used with `--cpu-post` or `--cpu-frames`.

Only the newest frame is kept for the model, so a busy GPU skips frames
instead of queueing them.

4. **Delivery:** the client connects to TCP port 47901 once its stream is up
   (`src/depth_server.rs`). Each map goes out with a 32-byte header carrying
   its frame number, compressed with zstd (a 384x384 map is about 44 KB, so
   about 25 Mbit/s at 72 Hz). If the network falls behind, only the newest
   map is sent next. Only a client that is streaming through Meteor gets
   maps, and only from its own video. Discovery advertises the port, size
   and model while host depth is on and a model is loaded.

The model only runs while a client is connected to the depth port (or with
`--save-depth`). Decoding never stops, because NVDEC can only restart on a
keyframe and Sunshine rarely sends one.

The tray has the controls:
- a **Host depth** on/off toggle;
- a **Model** menu, listing the `.onnx` files in the models folder;
- a **Rate** menu: Match stream, 30, 60, 72, 90 or 120 Hz (72 Hz is the Quest default refresh rate);
- a live readout of the rate and timings.

Choices are kept in `state.toml`, next to `meteor.toml`.

Requirements:
- An NVIDIA GPU and driver (Meteor uses the driver's `libcuda` and
  `libnvcuvid`).
- ONNX Runtime with the CUDA provider. For now this comes from the
  `onnxruntime-gpu` pip package; set it up once with
  `tools/bench_depth.py`'s instructions, which put it in `target/bench-venv`
  where development builds find it. Otherwise set `onnxruntime_lib`.
- Optional: TensorRT 10 (`tensorrt-cu13<11` from pip, in the same venv).
  ONNX Runtime 1.30 links TensorRT 10, so version 11 won't load. Without
  it, Meteor stays on CUDA.
- Models in `~/.local/share/nightfall-meteor/models` (`models_dir` changes
  this). Fixed-size ZipDepth exports work. Use
  `tools/ZipDepth/onnx_export/zipdepth_base_384.onnx` (with its
  `_raw.onnx.data`) for now: other sizes and aspect ratios have produced
  corrupt or wrong depth maps and are being investigated.

Without these, Meteor logs why and stays a plain proxy.

Measured on an RTX 3090 (2026-10-03):

| | |
|---|---|
| ZipDepth 384x384, model time | CUDA 1.8 ms, TensorRT fp16 0.85 ms median (`tools/bench_depth.py`) |
| Frame in to depth map out, 72 and 120 fps | **1.8 ms median, about 3 ms p95** |
| Stages | decode 0.82 ms, handoff 0.01 ms, model 0.84 ms, post-processing 0.11 ms |
| Same with `--cpu-post` | 3.0 ms median (post-processing 1.07 ms) |
| Same with `--cpu-post --no-tensorrt` | 3.6-3.9 ms (72 fps), 3.4-3.6 ms (120 fps) median |
| Same with `--cpu-frames --no-tensorrt` | 6.0-6.4 ms (72 fps), 4.9-5.6 ms (120 fps) median |
| TensorRT fp16 vs CUDA depth maps | 0.4 grey levels on average, 3 at most |
| GPU vs CPU frame conversion | identical output, frame and depth map |
| Rust output vs a Python reference | within 1 grey level |
| NVDEC colours vs ffmpeg's decode | within about 2 levels (PSNR 32.5 dB) |

These figures leave out the first second, which includes one-off CUDA
start-up of about 270 ms. The worse tail at 72 fps is likely the GPU clocking
down between frames on an otherwise idle desktop.

The kernels are checked in as PTX and embedded in the binary. After
editing a `.cu` file, rebuild with `tools/build_kernels.py`. It uses NVRTC,
needs no host compiler, and turns off fused multiply-add so the GPU matches
the CPU code exactly. `--replay` prints the median time of each stage.

Debugging:
- `--dump-video <dir>` writes the tapped stream; play it with
  `ffplay -f hevc <file>`.
- `--save-depth <dir>` saves every Nth frame and its map as PNGs.
- `--replay <file.hevc>` runs a recorded stream through the pipeline without
  a client and prints timings. The depth port is open during a replay, for
  a local test client.

## Microphone

Meteor creates a **Nightfall Microphone** input device. It's a PipeWire
virtual source fed by a `pw-cat` child process; with no `pw-cat`, Meteor
falls back to `module-pipe-source`, which adds about 260 ms. The device is
removed when Meteor exits.

The headset sends 10 ms PCM packets to UDP 47902 (format in `src/mic.rs`).
Meteor accepts them only from loopback or from a client that is streaming
through it. Discovery advertises the port under `"mic"`.

The tray shows the microphone's status, with **Mute microphone** and **Set as
default input**.

To test without a headset:
`python3 tools/send_mic.py --tone 440 --seconds 10`, then record from the
device (`pw-record --target nightfall_mic out.wav`). `--loss` and
`--jitter-ms` simulate a poor network.

Measured: a tone comes out of the device 80-105 ms after the first packet is
sent. That includes the 40 ms jitter buffer, the 30 ms start cushion, and the
recorder's own buffering.

## Settings

`~/.config/nightfall-meteor/meteor.toml` (`%APPDATA%\Nightfall Meteor\meteor.toml`
on Windows). The tray's "Open settings file" creates it with the defaults
commented out:

```toml
# sunshine_host = "127.0.0.1"
# sunshine_port = 47989    # detected from sunshine.conf when unset
# port_offset = 1000
# discovery_port = 47900   # the client expects 47900
# onnxruntime_lib = "/path/to/libonnxruntime.so.1.30.0"
# models_dir = "/home/you/.local/share/nightfall-meteor/models"
# tensorrt = true
```

When `sunshine_port` is unset, Meteor reads `port` from the Sunshine, Apollo,
Vibepollo, and Polaris config files and uses the first one that is listening.

## Tests

```
cargo test
```

Client side: `test/test_meteor_client.gd` (in `test/run_gdscript_tests.sh`).
