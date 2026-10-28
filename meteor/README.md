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
  appears as the "Meteor" AI 3D model, matched to the frame on screen
  (Phase 3).
- **Microphone:** the Quest sends encrypted audio to Meteor. Linux exposes a
  "Nightfall Microphone" device; Windows plays it into VB-CABLE, where apps
  record from CABLE Output. Both have been tested with the headset.

## Running

```
cd meteor
cargo run --release            # tray icon
cargo run --release -- --no-tray
```

`--help` lists the debug options (`--dump-video`, `--save-depth`, `--replay`,
`--no-depth`, `--no-mic`). Set `RUST_LOG=debug` for per-connection logging. On
Linux the tray uses StatusNotifierItem; on Windows it uses the notification
area. macOS runs without a tray icon for now.

### Managed Linux XR (development preview)

Release dependencies, licenses, source companion and reproducible build inputs
are documented in [RELEASE.md](RELEASE.md), also accessible from the tray's
**Release information & licenses** item.

The XR-enabled preview AppImage includes a managed Monado runtime, NVIDIA/AMD
encoding and tracking bridges and an independently built xrizer OpenVR compatibility
runtime. WiVRN and SteamVR installations are not required.

Run the AppImage and select **Enable PCVR — install & restart Meteor** near the
top of its tray menu. This installs the verified runtime into your user-data
folder, enables XR and restarts Meteor. Existing settings/comments are retained,
with a backup before the setting is changed; headset approvals are preserved.
The menu shows **PCVR ready** when the service is running, or an error and Retry
action if setup/startup fails. Desktop streams briefly disconnect during restart.

For command-line setup, this performs the same install/enable steps and exits:

```sh
./Nightfall-Meteor-0.1.1-XR-DEV-x86_64.AppImage --enable-xr
```

The install-only command remains available:

```sh
./Nightfall-Meteor-0.1.1-XR-DEV-x86_64.AppImage --install-xr-runtime
```

This copies files only; it does not change global OpenXR selection, Steam launch
options, headset authorization or running services. Python 3, compatible host
Vulkan/udev/C++ libraries and matching graphics drivers remain required for XR.
NVIDIA uses CUDA/NVENC. Experimental AMD XR uses host libva/DRM/Mesa with a
hardware H.264/HEVC encoder and VA video processing. Meteor includes the FFmpeg
encoder runtime, so a system FFmpeg installation is not required for gameplay.
The RX480 has passed packaged synthetic/transport tests; modern AMD cards and
real-game headset sessions still need validation.

**PCVR encoder** in the tray selects Auto, NVIDIA/NVENC or AMD/VA-API for the next
XR session without restarting Meteor. Auto prefers NVIDIA on mixed systems;
AMD-only systems select AMD after checking codec/VPP capabilities. Rendering and
encoding use the same selected GPU; this does not change Sunshine or depth GPU
selection. Both H.264 and HEVC are available when the GPU advertises them. HEVC
is preferred on Quest 3; H.264 is the Quest 2 default when supported. Foveated
encoding is automatically greyed out and effectively Off on unsupported encoders,
without erasing the saved preference for NVIDIA. Set bitrate before the session; live bitrate changes
are explicitly rejected on AMD rather than silently ignored.

For multiple AMD GPUs, select the host-local render node in the config:

```toml
[xr]
encoder_backend = "vaapi" # auto | nvenc | vaapi
render_device = "/dev/dri/renderD128" # Check the actual node on this machine.
```

Selecting Auto or NVIDIA in the tray clears that explicit AMD override. Cards
without a supported hardware encoder are rejected; there is no CPU fallback.

Advanced users can also enable the installed XR service directly in
`~/.config/nightfall-meteor/meteor.toml` (respecting `XDG_CONFIG_HOME`), then restart Meteor:

```toml
[xr]
enabled = true
# Defaults: TCP control 47910, video 47911, tracking 47912.
```

With the updated Nightfall client streaming the matching desktop, XR discovery
uses Meteor's remembered host key. A new headset proves its identity, displays an
approval code, and waits for the matching local Approve action in Meteor's tray.
Meteor also shows an approval notification with Approve/Reject buttons and the
matching headset code. If notifications are disabled, use the tray actions.
Approvals persist across host restarts. An unapproved headset gets no XR session
or transport. Discovery and Sunshine pairing alone do not grant XR access.

Configured XR ports are included in the existing firewall check/Allow action;
firewall rules are never changed automatically. An XR startup failure leaves the
desktop proxy available. Runtime updates preserve settings/logs and refuse to run
during an active XR session.

The installer selects the bundled xrizer on fresh installs and migrates the known
WiVRN Flatpak compatibility path, preserving an explicit custom runtime choice.
Its OpenVR registry is private to owned game launches; global runtime selection
is unchanged. The pinned upstream revision, source URL and dependency notices
are included with the runtime.

This is not a finished clean-install release. Steam launch options still need
configuration. See the [installation plan](../docs/plans/active/meteor-linux-installation.md)
for the current evidence and remaining work. XR audio currently uses the retained
Sunshine stream.

At the top of Meteor's tray menu, **Custom Steam Launch Options required: Copy**
copies the installed launch command. In Steam, right-click each VR game, choose
**Properties → General → Launch Options**, and paste it. The same command works
for Steam games and non-Steam shortcuts: it reads the identity Steam supplies.
Existing per-game commands with explicit app IDs continue to work. Linux copy
uses KDE's clipboard service, or `wl-copy` / `xclip` on other desktops.

### Optional Vulkan VDA models

Under **GPU / model**, choose **Download VDA 518×294 (Vulkan)** or
**Download VDA Performance 392×224 (Vulkan)**. Both are conversions of the existing
VDA Small checkpoint and require no TensorRT/CUDA download. Files come from the
[VDA model release](https://github.com/tB0nE/nightfall/releases/tag/meteor-vda-s-518x294)
and are pinned by SHA-256. Downloads can be cancelled and resumed. Meteor adds a
model to compatible GPU groups only after its complete installation; your current
model and GPU remain selected. Each download includes the Apache 2.0 license.

For headless installation, use `--download-vda-vulkan 518` or
`--download-vda-vulkan 392`. NVIDIA's separate TensorRT VDA download remains
available under its clearly labelled menu entry.

### Integrated XR development service

On a configured Linux/NVIDIA development checkout, the XR endpoint can run
alongside the ordinary proxy instead of a separate `--xr-control-dev` process:

```sh
cargo run --release -- --no-tray --no-depth --no-mic \
  --xr-service-dev <local-address:port> \
  --xr-client-key <headset-public-key-hex> \
  --xr-runtime-root <absolute-nightfall-checkout>
```

This legacy CLI path remains opt-in and does not advertise XR in discovery.
A configured checkout runtime can supervise a host-selected application after
explicit acceptance and authenticated relay attachment; without it, only the
encrypted relay endpoints are prepared. Existing checkout prerequisites apply.
Only public keys belong on the command line; never pass a private key or password.

Unlike the standalone DEV endpoint's separate key file, this mode uses Meteor's
normal `meteor.key` identity. Its **public** key is printed at startup: explicitly
update the DEV headset host pin if necessary, rather than disabling pin checks.
The client allowlist remains mandatory; discovery and a streaming IP address are
not substitutes for device authorization. No XR capability is added to discovery,
firewall rules are not changed, and the normal client still requires its DEV entry.
An XR bind/configuration failure leaves the desktop proxy available and is logged.

Tray Quit and termination signals request service shutdown; Meteor awaits XR's
bounded runtime cleanup, removes its microphone, then uses its existing immediate
exit to avoid unsafe GPU-library destructors. The desktop-overlay and real-game
session-detection work is tracked in
[the integration plan](../docs/plans/active/meteor-xr-desktop-integration.md).

Process-level coexistence regression (temporary configuration, test-only keys,
mock Sunshine HTTP upstream; no headset/GPU or running-service replacement):

```sh
python3 test/run_meteor_xr_coexistence.py \
  meteor/target/release/nightfall-meteor /path/to/meteor-xr-control-cpp-client
```

Run that from the repository root with the OpenSSL control fixture built from
`test/meteor_xr_control_client_test.cpp`. It checks authenticated negotiation plus
proxy forwarding, XR bind-failure isolation, XR-disabled startup and signal exits.
It is not full GameStream/video coverage. Runtime status is an optional field on
authenticated replies; client polling never treats session activity as proof of
headset presentation or automatically enters XR.

### Building the AppImage

```
meteor/tools/build_appimage.sh [models folder]
```

Builds `meteor/target/appimage/Nightfall-Meteor-<version>-x86_64.AppImage` with:

- Meteor without ONNX Runtime, optimized in Ubuntu 22.04 for glibc 2.35+;
- ncnn, its OpenMP runtime and the portable Vulkan processing library;
- EdgePad-512 and EdgePad-256;
- minimal FFmpeg/dav1d runtime (including HEVC VA-API encoding) and component notices.

Set `NIGHTFALL_CONTAINER_ENGINE=docker` or `podman` to choose the builder.
The model folder (default `~/.local/share/nightfall-meteor/models`) must contain
`zipdepth_wide_512x288.ncnn.{param,bin}` and
`zipdepth_edgepad_256.ncnn.{param,bin}`.

To include the managed XR preview, first prepare its baseline-compatible bundle,
then build:

```sh
bash tools/build_support/build_meteor_xr_bundle.sh
NIGHTFALL_CONTAINER_ENGINE=docker \
METEOR_XR_BUNDLE="$PWD/.build-cache/meteor-xr/portable-package/bundle" \
bash meteor/tools/build_appimage.sh
```

XR builds use the distinct `Nightfall-Meteor-<version>-XR-DEV-x86_64.AppImage`
filename and remain release-optimized. The build validates runtime integrity and
ELF compatibility before packaging it. XR notices remain inside the verified
bundle under `usr/share/nightfall-meteor/xr-bundle`.

Vulkan VDA exports are not included merely because they exist on the build PC.
Explicit `METEOR_BUNDLE_VDA_VULKAN=1` includes both variants if present, subject to
the unchanged 100 MB package limit. Installed user models remain available;
separate Vulkan VDA download delivery is still pending. The existing tray VDA
download installs the NVIDIA TensorRT assets.

### Windows release folder

From Windows PowerShell in `meteor`, run:

```powershell
.\tools\build_windows_release.ps1
```

The script builds with `cargo build --release --locked --no-default-features`
and creates `target\windows-release\Nightfall-Meteor-<version>-windows-x64.zip`.
It takes EdgePad 512 from `%LOCALAPPDATA%\Nightfall Meteor\models` by default;
pass `-ModelsDir` to use another folder. It fetches ncnn's pinned Windows
release and verifies the DLL and licence hashes; pass `-NcnnDir` for a folder
already holding `ncnn.dll` and `LICENSE.txt`. The first run installs
`cargo-about` to generate third-party notices. The zip contains the exe,
ncnn, EdgePad 512, README, licence and notices. It requires the Microsoft
Visual C++ x64 Redistributable on the destination PC. The zip does not set
up firewall rules or install a Start menu entry. The installer adds the
Start menu entry but does not change firewall rules yet.

Inside the zip, keep `nightfall-meteor.exe` and `ncnn.dll` together, with
EdgePad's `.ncnn.param` and `.ncnn.bin` in
`share/nightfall-meteor/models/` beside the executable.

### Windows installer

Install Inno Setup 7, then run from Windows PowerShell in `meteor`:

```powershell
.\tools\build_windows_installer.ps1
```

It rebuilds the release folder and creates
`target\windows-release\Nightfall-Meteor-<version>-Setup-x64.exe`. The same
`-ModelsDir` and `-NcnnDir` options work. The installer is per-user: it puts
the app under `%LOCALAPPDATA%\Programs\Nightfall Meteor`, creates Start menu
and uninstall entries, offers a desktop shortcut, and can launch Meteor at
the end. It needs no administrator rights. It leaves the pairing key,
downloaded VDA files, and settings in AppData during uninstall. The Visual
C++ x64 Redistributable remains a prerequisite, and Windows Firewall may
need its first-run private-network prompt. Before installing, quit a portable
Meteor process if one is running; only one instance can listen on the ports.
EdgePad is the default. The Windows tray's **Depth model** menu offers the
VDA download, with progress and Cancel. It fetches the VDA graphs from the
Nightfall release and only the needed DLLs from NVIDIA's Windows TensorRT
wheel; the files are checked against pinned SHA-256 hashes. On the RTX 3090,
the download is about 472 MB and the first engine build took about five
minutes. The Windows download is currently pinned for the sm86 GPU resource;
other NVIDIA GPUs still need their signed DLL hashes added. `--download-vda`
offers the same download from a console. Meteor also finds pre-supplied VDA
files in `share/nightfall-meteor/models/` and `tensorrt/` beside the exe.

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

The **GPU / model** menu groups compatible models beneath each detected GPU.
Choosing an entry saves the GPU, model and CPU/GPU mode together and queues one
background reload; the stream does not restart. There is one group per GPU and
a **CPU** group for single-frame models. Existing automatic GPU selections
resolve to NVIDIA when available, otherwise ncnn's default GPU.
Status reports the model and GPU actually loaded. Missing explicitly selected
GPUs fail visibly. Identical-name GPUs are not yet individually distinguishable.

EdgePad uses ncnn Vulkan on NVIDIA, AMD or Intel with a suitable driver. The new
Vulkan VDA variants retain the learned reconstruction and temporal history:

- **VDA 518×294**: original resolution.
- **VDA Performance 392×224**: the lower-compute option.

VDA entries appear when their optional runtime, model exports and GPU capabilities
are available. VDA is not offered under CPU. On NVIDIA, Vulkan and TensorRT
models appear together, with the backend in the VDA model label. TensorRT uses
the default CUDA GPU; with multiple NVIDIA GPUs it is listed only under the first
detected NVIDIA GPU. Existing saved TensorRT selections retain
their behavior. Selecting a Vulkan GPU does not move desktop capture, encoding
or the PCVR compositor. Driver overrides that hide GPUs also hide them here.

#### Building/staging Vulkan VDA

`cargo build --release --no-default-features` builds the optional native runner
when the matching ncnn SDK is at `meteor/target/ncnn` (Linux), or
`METEOR_VDA_NCNN_SDK` names its root. Windows packaging supplies the MSVC SDK
explicitly. Without the SDK, Meteor builds without this optional runtime.
Packaged runtimes live beside the executable, or in the AppImage's `usr/lib`.

Stage the validated repaired exports, not the unrepaired pnnx graphs:

```sh
.build-cache/model-tester-venv/bin/python meteor/tools/stage_vda_vulkan_models.py \
    --source .build-cache/vda-vulkan-spike \
    --destination ~/.local/share/nightfall-meteor/models
```

Each variant has its own subdirectory and SHA-256 manifest. This staging tool
refuses to overwrite different weights. Linux/Windows packaging includes these
optional model directories when present in its model source folder. Existing
TensorRT downloads do not install the Vulkan exports.

The persistent runner shares the validated kernels with the research tools.
NVIDIA uses cooperative-matrix Tensor Core kernels when supported; RX480 uses
FP32 arithmetic, FP16 storage and wave64 reductions. Other supported GPUs use a
portable fallback rather than blindly requiring wave64 or Tensor Cores. Intel,
newer AMD cards and Windows still need hardware validation. History resets on a
new stream, gaps over 500 ms, hard cuts and nonfinite output. State validity is
checked on GPU. Initialization settings are thread-local; probe environment flags
cannot silently change production kernels. Failed VDA inference uses the existing
three-failure recovery to a single-frame model.

Vulkan frame processing also accelerates the surrounding image operations:
NV12 footprint filtering, VDA bicubic resize/normalization, scene-cut thumbnail
reduction, depth softening, and final histogram/smoothing/alignment/cleanup.
The prepared VDA tensor stays on Vulkan through inference. Portable EdgePad and
VDA keep their output depth on Vulkan through final processing; only packed 8-bit
maps and a small validation flag are downloaded. CPU reference processing and
fallback readback remain available. Decoder surfaces still have host transfers;
this is not VAAPI/Vulkan zero-copy.
Portable VDA preparation skips frames while inference is busy rather than queueing
another GPU filter behind a long model run. Short EdgePad jobs retain pipelined
preparation. The decoder keeps consuming packets, and the next available VDA frame
starts fresh preparation. Portable preparation also skips pixel conversion when
there are no depth subscribers or snapshot requests.

Standalone original-resolution RX480 graph timings were about 75 ms, Performance
about 43 ms. Live decode, preparation, transfers, validity checks, softening and
refinement add cost; these are not end-to-end stream latency guarantees.

### Advanced depth pipeline

- **Video decoder:** Auto, NVDEC (NVIDIA), VAAPI (Linux), or Software (CPU).
  Auto prefers VAAPI when Vulkan inference is assigned to AMD, otherwise NVDEC, and can
  fall back to VAAPI/software with a logged reason. Explicit choices fail
  visibly instead of silently selecting a different backend.
- **VAAPI decode GPU:** Auto or a DRM render device identified by GPU vendor and
  PCI address. This is independent of the inference GPU; device paths persist
  across renderD-number reorder.
- **CPU frame processing:** forces the CPU reference preparation and refinement
  for EdgePad and Vulkan VDA. With this off, VAAPI/software frames use Vulkan
  preparation/refinement on the selected inference GPU, falling back to CPU with
  a logged reason if those optional operations are unavailable. Vulkan VDA does
  not require CUDA/TensorRT.

Settings are saved under `[decode]` in `state.toml`. Decoder/device changes apply
at the next keyframe or new stream. Active backend/device and processing are
shown in the advanced menu and logged. Inference-GPU changes retain their live
model reload behavior.

On Linux, AMD-only EdgePad now uses in-process FFmpeg VAAPI (or software) decoding,
the existing 4×4 footprint RGB filter on CPU, ncnn Vulkan inference on AMD, and
CPU smoothing/alignment/contour cleanup. The optimized footprint filter is tested
byte-for-byte against the existing reference. Decode output is tagged with its
actual source frame ID, including B-frame reordering; no ffmpeg subprocess is
used for the stream. CPU copies and processing can cost more than NVIDIA's CUDA
path—compare complete stream-to-map latency, not just inference time.

The optional runtime requires FFmpeg 8 ABI libraries: avcodec 62, avutil 60 and
swscale 9. `METEOR_FFMPEG_DIR` can specify a runtime folder. Linux packaging builds
and bundles a minimal FFmpeg runtime; VAAPI still requires the host's libva
runtime and graphics driver. Windows has the software adapter and menu controls,
but VAAPI is Linux-only, FFmpeg DLL bundling and Windows validation are outstanding.
TensorRT VDA and the development PCVR compositor/encoder remain NVIDIA-only; Vulkan VDA does not.

The **GPU / model** menu offers GPU and CPU groups for EdgePad models. GPU remains
the default; CPU reuses the existing ncnn/ONNX weights without retraining.
Changing this reloads inference without restarting Meteor or the stream, and
the choice is saved in `state.toml`. CPU uses fp32 and at most four workers
(half the available logical CPUs, minimum one) to leave capacity for games.
Status reports the active backend. A failed CPU load does not silently keep
the previous GPU inference running.

CPU inference is independent of the decoder selection: choose VAAPI/software
decoding for a path that does not require NVIDIA. NVDEC retains its CUDA input
conversion unless CPU frame processing is requested. Depth post-processing runs
on CPU for CPU model outputs.
VDA's live temporal pipeline still requires GPU: select EdgePad to enable CPU.
CPU performance is hardware-dependent; test sustained update rate and game
frame times rather than assuming that spare CPU capacity guarantees low latency.

Meteor copies each forwarded video packet to a tap, after forwarding it. The
tap rebuilds whole frames (`src/video_tap.rs`, a port of moonlight-common-c's
reassembly, keeping only the data shards). Each frame then goes through:

1. **Decode:** NVDEC, called directly through the NVIDIA driver
   (`src/nvdec.rs`), decodes the frame at full size as soon as it's complete.
   A small CUDA kernel (`kernels/nv12_to_tensor.cu`) then reduces it to the
   model's input with the Quest's 4x4 footprint average (so host depth sees
   the same input as on-device depth; NVDEC's own scaler aliases text and
   fine detail) and writes the model's input tensor directly in GPU memory, and ONNX Runtime reads it in place, so the frame
   never passes through the CPU. Each frame stays tagged with its frame
   number. `--cpu-frames` switches to converting on the CPU, for
   comparison.
2. **Model:** the EdgePad models run on ncnn's Vulkan backend
   (`src/ncnn.rs`), which loads in under a second and needs no NVIDIA
   inference libraries. Vulkan can't read CUDA memory, so NVDEC input tensors
   come back through the CPU first; CUDA refinement still uses NVDEC's guide.
   VAAPI/software decoding instead uses Vulkan footprint filtering and Vulkan
   depth refinement, with CPU processing as an explicit reference/fallback path.
   Without ncnn (or with `METEOR_NCNN=off`), ONNX Runtime runs the `.onnx`
   versions (`src/onnx.rs`): it starts on CUDA within a second, builds a
   TensorRT fp16 engine in the background, and switches to it. The first
   build takes about 90 s per model and GPU; after that the engine is cached
   in `~/.cache/nightfall-meteor/tensorrt` and loads in about 0.4 s. Set
   `tensorrt = false`, or pass `--no-tensorrt`, to stay on CUDA.
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
- a **Model** menu, listing the models in the models folder (each EdgePad
  model once, on ncnn when it has been converted, and Video Depth
  Anything, below);
- a **Rate** menu: Match stream, 20, 30, 60, 72, 90 or 120 Hz (72 Hz is the Quest default refresh rate);
- **Depth smoothing**, the per-pixel smoothing in post-processing,
  remembered per model: on by default for EdgePad, off for VDA, which is
  temporally steady already (smoothing adds about 40 ms of lag);
- **Edge softening (VDA)**: Off, Light, Medium (default) or High, a
  Gaussian blur of 0.75, 0.85 or 1 depth texel (sigma).
  The headset's stereo warp shifts the picture in blocks of one depth texel
  (about 5x5 screen pixels at 1440p), so a hard edge shows those blocks as
  jaggies; softened, it becomes a slope the warp stretches smoothly. VDA's
  temporal stability is unaffected;
- a live readout of the rate and timings.

### Experimental depth refinement

The Linux and Windows trays also offer two live switches, both on by default
(including older settings without these keys). Explicit saved Off choices
remain respected:

- **Edge alignment (experimental)**: the Bounded-2 colour-guided boundary
  adjustment. Searches within two native depth texels, with confidence gates
  and 75% strength; flat depth is left alone.
- **Contour cleanup (requires alignment)**: Bounded-4, applied **after**
  Bounded-2. Smooths along the contour, with thin-feature protection and a
  bounded change, rather than blurring across the depth edge. Its saved choice
  is retained when alignment is disabled, but it does not run independently.

Both apply to EdgePad and VDA, after existing normalization/temporal smoothing
and VDA softening, before sending the map. They do not change temporal history,
model inference, map dimensions, frame matching or the headset protocol.
No restart or new model is needed; changes take effect on subsequent maps.

GPU-decoded frames use **CUDA refinement** directly against NVDEC's existing
RGB tensor. Only the small 8-bit map is uploaded/downloaded; no colour readback
is needed. A slower CPU reference handles CPU frames or a CUDA refinement
failure (logged explicitly). It adds processing time, included in the existing
post/total timings; `RUST_LOG=debug` logs the backend and refinement milliseconds,
including transfers. Disabled costs no colour download or refinement pass.
This remains an experimental quality comparison, not a claim of improved
performance. The CPU reference can be expensive on edge-heavy scenes.

Initial release-mode synthetic timings on the development GPU, after warm-up:
alignment approximately **0.13–0.14 ms**, alignment plus cleanup **0.14–0.17 ms**
at 384x384, 512x288 and 518x294 (30 iterations; includes map transfers, excludes
model inference and one-time CUDA initialization). These are isolated pass
measurements, not live-stream latency guarantees. The deliberately edge-heavy
CPU reference benchmark took roughly 77–103 ms; the normal GPU-frame path
does not use it. Reproduce with `cargo test --release --locked
--no-default-features benchmark_cuda_refinement -- --ignored --nocapture`
from `meteor/` on an NVIDIA GPU.

Unlike the local comparison, live Meteor uses the **model-input-resolution RGB
guide** and refines the **native output grid**, not the full-resolution original
guide and quarter-stream working grid. Thus the algorithm is the same, but the
results need live evaluation (especially VDA and fine edges). Bounded-2's
intermediate is rounded to 8-bit, and final cleanup is quantized to the existing
8-bit wire map; the local cleanup preview used a half-float render target.

Choices are kept in `state.toml`, next to `meteor.toml`.

Requirements:
- An NVIDIA GPU and driver (Meteor uses the driver's `libcuda` and
  `libnvcuvid`).
- ncnn (Vulkan) for the EdgePad models: `tools/fetch_ncnn.sh` puts ncnn's
  prebuilt library in `target/ncnn`, where development builds find it.
  Otherwise set `ncnn_lib`.
- TensorRT 10 for VDA. Meteor opens `libnvinfer` and `libnvonnxparser`
  from `tensorrt_dir` in meteor.toml, the VDA download's folder, the
  development venv (`target/bench-venv`, `tensorrt-cu13<11` from pip), or
  the library path.
- **The VDA download** (`src/download.rs`). When VDA can't run yet, the
  tray's Model menu offers "Download Video Depth Anything (N MB)". The
  submenu says TensorRT comes from NVIDIA under NVIDIA's licence, links to
  that licence, and has "Accept and download". `nightfall-meteor
  --download-vda` does the same from a terminal. It fetches:
  - from NVIDIA's package server, only `libnvinfer`, the ONNX parser and
    this GPU's builder resource, by range requests into the 3.7 GB
    `tensorrt_cu13_libs` 10.16.1.11 wheel (462 MB on an RTX 30);
  - the two VDA graphs from our release (`METEOR_VDA_URL` overrides the
    folder URL), 239 MB.

  Each file is checked against a pinned SHA-256, then renamed into place:
  TensorRT into `~/.local/share/nightfall-meteor/runtime/tensorrt-10.16.1`,
  the graphs into the models folder. Meteor then switches to VDA, building
  its engines while the current model keeps serving. "Remove the VDA
  download" deletes TensorRT, the graphs it fetched and VDA's engines.
- Optional, for development: ONNX Runtime with the CUDA provider. It runs
  the `.onnx` EdgePad models without ncnn, and VDA on CUDA while its
  engines build (without it, an EdgePad model serves meanwhile). It comes
  from the `onnxruntime-gpu` pip package; set it up once with
  `tools/bench_depth.py`'s instructions, which put it in
  `target/bench-venv` where development builds find it, or set
  `onnxruntime_lib`. ONNX Runtime 1.30 links TensorRT 10, so version 11
  won't load. Builds with `--no-default-features` leave ONNX Runtime out
  (the `onnxruntime` feature), as the AppImage will.
- Models in `~/.local/share/nightfall-meteor/models` (`models_dir` changes
  this), and those shipped in `../share/nightfall-meteor/models` next to
  the binary (the AppImage); a file of the same name in the models folder
  wins. The tray's Model menu lists them. Meteor defaults to
  `zipdepth_wide_512x288.onnx`, the widescreen EdgePad model the Quest's
  standard tier also runs; `zipdepth_wide_672x384.onnx` is the
  higher-quality choice (about 0.6 ms more per frame). Both come from the
  model researcher's exports (`nightfall-temporal-zipdepth`, see its
  `reports/NIGHTFALL_WIDESCREEN_FAMILY_HANDOFF.md`). Build them once with
  `make_host_model.py`, which unpacks the packed EdgePad output in the graph
  and checks the result against the matching `.tflite`:

  ```sh
  E=../nightfall-temporal-zipdepth/local-data/exports
  python meteor/tools/make_host_model.py \
      $E/cheap_widescreen_active16x9_gate_d_final/512x288/student_512x288_edgepad.onnx \
      ~/.local/share/nightfall-meteor/models/zipdepth_wide_512x288.onnx \
      $E/cheap_widescreen_active16x9_gate_d_final/512x288/tflite/student_512x288_edgepad_float16.tflite
  python meteor/tools/make_host_model.py \
      $E/host_strong_zero_shot/672x384/student_672x384_edgepad.onnx \
      ~/.local/share/nightfall-meteor/models/zipdepth_wide_672x384.onnx \
      $E/host_strong_zero_shot/672x384/tflite/student_672x384_edgepad_float16.tflite
  ```

  Then convert them for ncnn (needs `pip install pnnx`; see
  `models/README.md`):

  ```sh
  M=~/.local/share/nightfall-meteor/models
  python meteor/models/convert_ncnn.py $M/zipdepth_wide_512x288.onnx $M/zipdepth_wide_672x384.onnx
  ```

  Without the conversion, the first use of a model on ONNX Runtime builds
  its TensorRT engine (about 100 s, then cached).
- Optional: **Video Depth Anything Small (518x294)** (`src/vda.rs`), a
  temporal model: it keeps eight hidden-state histories between frames
  instead of seeing each frame alone. It's a manual choice for testing; the
  default stays the EdgePad 512x288 model. The tray downloads it (Model,
  then "Download Video Depth Anything"). Or repack the model researcher's
  two graphs from `experiments/video_depth_anything_small/artifacts/tensorrt_518x294/`
  into the models folder; they appear as one entry:

  ```sh
  A=../nightfall-temporal-zipdepth/experiments/video_depth_anything_small/artifacts/tensorrt_518x294
  python meteor/models/share_vda_weights.py $A/vda_s_streaming_step_518x294.onnx \
      $A/vda_s_cold_start_518x294.onnx --out ~/.local/share/nightfall-meteor/models
  ```

  The researcher's graphs each hold the full weights. The repack stores
  them once in `vda_s_518x294.onnx.data`, which both graphs read (239 MB
  becomes 126 MB; see `models/README.md`). Meteor checks all three files'
  SHA-256 before loading them. The first frame
  after a reset runs the cold-start graph (TensorRT fp32, optimisation level
  0, about 8 ms); every later frame runs the recurrent step (TensorRT fp16,
  about 3.9 ms on an RTX 3090) with 31 of its earlier states. Frames are
  reduced to 720p by the decoder and resized to 518x294 with OpenCV's
  bicubic filter on the GPU, as in the researcher's reference. The state
  starts again on a new stream, after a pause of over 0.5 s, on a hard cut
  (a large change in a 16x9 thumbnail), and after any non-finite output.
  If VDA fails to load, or fails three frames in a row, Meteor goes back to
  the previous model. VDA runs on TensorRT directly, without ONNX Runtime
  (`src/tensorrt.rs`), about 3.1 ms a step on an RTX 3090;
  `METEOR_TENSORRT=ort` uses ONNX Runtime's TensorRT provider instead. The
  first TensorRT build takes about 3 minutes, in a child process
  (`nightfall-meteor --build-tensorrt`; CUDA runs VDA meanwhile, at about
  11 ms a frame). The engines are cached per graph hash, precision, builder
  level, TensorRT version and GPU, and load in about 0.3 s.
  Every 10 s the log reports steps per second and p50/p95 times for each
  stage, and each cold start and its reason. Its depth has the same
  polarity as EdgePad's (near is bright). The square `zipdepth_edgepad_384.onnx` (built the same way from
  `tools/ZipDepth/onnx_export/zipdepth_base_384_standard_packed_conv4_reduceconv_edgepad.onnx`)
  still works if it's in the folder.

Without these, Meteor logs why and stays a plain proxy.

EdgePad-256 is a manual, lower-compute option for weaker GPUs, using the
same optimized square EdgePad-256 model as the headset. Release packages
include it alongside the default widescreen EdgePad-512. Select
**Model → EdgePad-256 (lower GPU load)**; it also supports CPU inference.
The default remains EdgePad-512. Lower resolution trades some detail for
less inference work, not smaller weights or necessarily less GPU memory.

EdgePad 512 on ncnn, measured on an RTX 3090 (2026-10-07):
- Against ONNX Runtime CUDA fp32 on 30 frames of a 1440p game capture
  (`cargo test --release -- --ignored edgepad`, which needs the frames):
  0.061% of the depth range on average, 0.72% at worst. TensorRT fp16,
  which Meteor ran before, is 0.068% and 0.85%.
- Run back to back: 2.5 ms median, 3.2 ms p95, upload and download included.
- Replaying the 1440p capture at 120 fps: frame in to map out 5.8-6.0 ms
  median, 14-15 ms p95 (decode 1.6 ms, model 3.4 ms, post-processing
  0.9 ms). TensorRT fp16 through ONNX Runtime: 3.1 ms median, 5.4 ms p95.
  The model is slower in the replay than back to back because the GPU
  switches between NVDEC's CUDA work and Vulkan, and clocks down between
  frames.

VDA measured on an RTX 3090 (2026-10-06):
- Against the researcher's all-TensorRT reference over their 75-frame
  sequence (`cargo build --release`, then `cargo test --release -- --ignored
  vda`, which needs their data):
  depth correlation 0.99995 mean, 0.99972 worst, from their inputs and from
  the 720p frames through the resize kernel.
- Replaying a 1440p 60 fps recording: 59 maps/s; prepare 0.44 ms, model
  3.85/4.25 ms (p50/p95), storing states 0.09 ms, post-processing 0.15 ms;
  frame in to map out 6.4 ms median. About 1 GB of GPU memory with both
  engines loaded (195 MB of it Meteor's own buffers).

On Windows with the same RTX 3090 (2026-10-08), VDA's 75-frame reference
test passed at 0.999939 mean correlation from model inputs and 0.999506 from
720p frames. A 1440p capture replayed at 120 fps produced 3774 maps from
3796 frames, with 6.6 ms median and 7.3 ms p95 frame-to-map time. The model
step took about 4.5 ms median; the two engines used 704 MiB of GPU memory.
Model changes during a stream update NVDEC's reduction size on the next frame;
they do not wait for a new video keyframe.

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
- `--dump-video <dir>` writes the tapped video, plus `<file>.frames.tsv`
  with each frame's arrival time (`tools/verify.py e2e`).
- `--save-depth <dir>` saves every Nth frame and its map as PNGs.
- `--replay <file.hevc>` runs a recorded stream through the pipeline without
  a client and prints timings. The depth port is open during a replay, for
  a local test client. `--jitter-ms <ms>` moves each frame's arrival up to
  that much early or late, as a network does (`tools/verify.py gpu depth`).

## Microphone

On Linux, Meteor creates a **Nightfall Microphone** input device. It's a PipeWire
virtual source fed by a `pw-cat` child process; with no `pw-cat`, Meteor
falls back to `module-pipe-source`, which adds about 260 ms. The device is
removed when Meteor exits.

The headset sends 10 ms PCM packets to UDP 47902, encrypted with AES-256-GCM
under a key agreed with X25519 (format in `src/mic.rs`), as Opus at 32 kbit/s
(about 83 kbit/s with headers) or raw PCM. Meteor decodes Opus at playout and
rebuilds a lost frame from the next packet's forward error correction, else
with loss concealment. It accepts packets only from loopback or from a client
that is streaming through it, and plain packets only from loopback.
Discovery advertises the port and formats under `"mic"`.

## Encryption and Meteor's key

Meteor makes an X25519 key on first run and keeps it in `meteor.key` in its
data folder (owner-only). Discovery publishes the public key as `"key"`; the
microphone and the depth maps are encrypted for it (AES-256-GCM, `src/crypto.rs`).
The headset remembers each host's key the first time it sees it and won't use
a Meteor whose key has changed; Settings > Forget Meteor Keys trusts a
reinstalled one. Deleting `meteor.key` makes a new key, which every headset
will refuse until it forgets the old one.

On Windows, install [VB-CABLE](https://vb-audio.com/Cable/index.htm) and reboot
as its installer instructs. Meteor sends microphone audio to **CABLE Input**;
choose **CABLE Output** as the microphone in Discord, a game, or Windows Sound
settings. The Windows tray shows microphone status and a mute control. Without
VB-CABLE, the proxy and depth features still start.

The Linux tray shows the microphone's status, with **Mute microphone** and
**Set as default input**.

To test without a headset:
`python3 tools/send_mic.py --tone 440 --seconds 10`, then record from the
device (`pw-record --target nightfall_mic out.wav`). `--loss` and
`--jitter-ms` simulate a poor network.

On Windows, `cargo run --release --no-default-features --example verify_windows_mic`
sends a short test tone to a running Meteor and confirms that it reaches
**CABLE Output**.

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
# ncnn_lib = "/path/to/libncnn.so.1"
# tensorrt_dir = "/path/to/tensorrt/lib"
# models_dir = "/home/you/.local/share/nightfall-meteor/models"
# tensorrt = true
```

When `sunshine_port` is unset, Meteor reads `port` from the Sunshine, Apollo,
Vibepollo, and Polaris config files and uses the first one that is listening.

### Optional managed streaming host (Linux preview)

On the first desktop launch, if no local Sunshine-family host is running or
installed/configured, Meteor offers to download and set up **Meteor-Vibepollo**.
Choose the notification's setup action to proceed, or dismiss it and keep using
your existing host. The same setup remains available in the tray menu. Headless
launches do not show this offer.

The portable host comes from the [dedicated preview release](https://github.com/tB0nE/Vibepollo/releases/tag/meteor-host-v0.1.0-preview.2).
Meteor pins its download size and SHA-256, checks the installed file manifest,
and installs it under `~/.local/share/nightfall-meteor/host/<version>/`.
Profiles and pairings live separately; installing a package does not replace
them. No system service, firewall or graphics configuration is installed by this
download. Graphics drivers and desktop/audio libraries still come from your OS.

For the managed host, Nightfall sends its PIN encrypted to Meteor. Compare the
PIN in the headset with the desktop notification, then choose **Approve**. The
same approval is available in the tray if notifications are hidden. Meteor
submits the approved PIN to its own host and Nightfall finishes pairing normally.
Requests expire after 60 seconds and never approve themselves. External hosts
and older Meteors retain the manual PIN/web-interface flow. The managed host
tray section still shows the web username and **Copy web UI password** for that
fallback. Desktop pairing and XR authorization remain separate approvals.

If virtual keyboard/mouse/gamepad access is missing, Meteor shows an input setup
notification and tray action. **Enable virtual input** requests administrator
approval to install a narrow udev rule for `uinput`/`uhid` on the active desktop
seat, loads the existing uinput module if necessary, and rechecks access before
restarting Meteor. It does not grant world-writable device access or change
group membership. Cancelling approval leaves streaming configuration unchanged.
Systems without udev/logind/polkit may need administrator-managed input access.

Changing from an existing host may require selecting and pairing the new host
in Nightfall; external host pairings are not imported into the managed host.

For download verification without switching hosts or starting services:

```sh
./Nightfall-Meteor.AppImage --download-host
```

Advanced `host_binary` overrides take precedence over the downloaded release.
Mixed-GPU streaming and capture backends require hardware testing.

Also in the tray, below the depth and microphone controls:
- **Start with my computer:** an entry in `~/.config/autostart`. The
  AppImage's first run turns it on, once, and Meteor updates the entry
  if the AppImage moves.
- **Open log:** `~/.local/state/nightfall-meteor/meteor.log`. Meteor
  logs there as well as to the terminal, and moves the file to
  `meteor.log.1` at 5 MB.

**Firewall:** Meteor checks at start that firewalld lets the Quest
through, in the zone of the interface the default route uses. If not,
the tray says "Firewall is blocking the Quest", and "Allow the Quest
through the firewall" opens the ports with one `pkexec` prompt. With ufw,
whose rules need root to read, the tray offers to open the ports in ufw.
The ports are TCP 47900, 47901, 48984, 48989 and 49010, and UDP 47902,
48998 to 49000 and 49002 (with the default offset and a host on the
default base port). Meteor's own ports (discovery, depth, microphone) sit
89, 88 and 87 below the host's base port, so a host on 49989 moves them to
49900 to 49902; see docs/plans/active/meteor-bundled-host.md. With the
bundled host, the host's own ports are opened too.

**Desktop notifications:**
- Starting Meteor while it's already running shows "already running".
- If there's no tray to show its icon in (GNOME without the AppIndicator
  extension), Meteor says it's running anyway.

## Tests

```
cargo test
```

Client side: `test/test_meteor_client.gd` (in `test/run_gdscript_tests.sh`).

## Managed XR development spike

Linux/NVIDIA development builds expose `--xr-dev <Nightfall-checkout> [--smoke]`
to supervise the isolated USB XR workflow without starting proxy/depth/audio.
This is not a packaged LAN XR feature. See
[managed session scope and setup](../docs/research/meteor-xr-managed-session.md).

The separate opt-in `--xr-control-dev` command exercises authenticated network
negotiation only. It cannot launch applications or stream LAN video. See the
[control prototype contract](../docs/research/meteor-xr-control-protocol.md).
