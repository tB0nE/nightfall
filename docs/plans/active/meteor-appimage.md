# Nightfall Meteor: AppImage

> Status: Phase 0 done (2026-10-07); Phases 1 to 5 planned.
>
> Date: 2026-10-07
>
> Related: [meteor-host-depth.md](meteor-host-depth.md) (host depth, the
> runtime size discussion), [meteor-windows.md](meteor-windows.md).
>
> Scope: Linux x86_64 hosts with an NVIDIA GPU (Turing or newer) and driver,
> running Sunshine, Apollo, Vibepollo or Vibeshine.

## Goal

Download one file, run it, and it works:

1. The user makes `Nightfall-Meteor-x86_64.AppImage` executable and runs it.
2. A tray icon appears. Meteor finds Sunshine, starts Video Depth Anything
   (VDA) by default, and adds itself to autostart.
3. The Quest finds Meteor the next time it connects to that PC and uses host
   depth. Nothing changes on the headset.

The user installs only the NVIDIA driver and Sunshine (or a fork), as they
already would to stream.

## Decisions

1. **Fat AppImage.** The GPU runtime (ONNX Runtime, TensorRT, and the CUDA
   libraries it needs) ships inside the AppImage. No downloads on first
   run. The small AppImage with a separate runtime download
   (meteor-host-depth.md, "Install size and the GPU runtime") comes later.
2. **Models bundled:** VDA-S 518x294 (both graphs, 240 MB) and EdgePad
   512x288 (25 MB). The 672x384 model is not bundled; users can still drop
   it in the models folder.
3. **VDA by default.** This changes the default from EdgePad 512 (the
   researcher's handoff asked us not to change defaults; this decision
   replaces that). EdgePad stays in the Model menu and is the fallback if
   VDA fails.
4. **Autostart on by default**, with a tray toggle to turn it off. Running
   the AppImage is taken as the user's intent to use Meteor.

## The size limit

GitHub release assets are limited to 2 GiB per file. Measured 2026-10-07
with zstd -15 (about what the AppImage's squashfs achieves):

| Bundle | Uncompressed | Compressed |
| --- | --- | --- |
| Everything in the development venv's runtime (all of cuDNN, cuBLAS, cudart, TensorRT with builder resources for sm75/86/89/120) and the 3 model files | 3.35 GB | 2.05 GiB: over |
| **Trimmed (Phase 0, below)** | 2.84 GB | **1.67 GiB** |

## Phase 0: trim the runtime (done, 2026-10-07)

Approach A works: TensorRT only, no CUDA path. Tested by pointing
`onnxruntime_lib` at a copy of the runtime holding only the files below,
with an empty engine cache, then again with the engines cached, for VDA and
EdgePad 512 (`--replay` of a 2560x1440 HEVC game capture at 120 fps).

**What ships** (each one is needed: leaving it out fails to link, errors
or crashes):

| File | Size | Why |
| --- | --- | --- |
| `libonnxruntime.so.1.30.0`, `_providers_shared`, `_providers_tensorrt` | 30 MB | ONNX Runtime and the TensorRT provider |
| `libonnxruntime_providers_cuda.so` | 272 MB | The TensorRT provider takes its GPU allocators from it ("CUDA Provider not available" without it) |
| `libcublas.so.13`, `libcublasLt.so.13` | 603 MB | Linked by both providers |
| `libcurand.so.10` | 126 MB | Linked by the CUDA provider |
| `libcudart.so.13` | 1 MB | |
| `libcudnn.so.9`, `libcudnn_graph.so.9` | 134 MB | The CUDA provider creates a cuDNN handle at start (abort in `cudnnCreate` without the graph library) |
| `libnvinfer.so.10`, `libnvonnxparser.so.10` | 668 MB | TensorRT |
| `libnvinfer_builder_resource_sm{75,86,89,120}.so.10.16.1` | 739 MB | Building engines on RTX 20/GTX 16, 30, 40, 50. Opened only during a build |
| VDA (2 graphs) and EdgePad 512 | 264 MB | |

**Left out:**
- cuDNN's engines, ops, heuristics, adv and cnn libraries (about 750 MB).
- `libnvinfer_plugin` (neither model uses it).
- The PTX and data-centre builders (sm80, sm90, sm100) and the Windows copies.
- cuFFT, NVRTC and nvJitLink.

cuBLASLt (545 MB) is the largest file that can't go: both providers link
it.

**Results on the RTX 3090:**

| | Trimmed | Full runtime |
| --- | --- | --- |
| VDA model step (p50) | 5.03 ms | 4.95 ms |
| EdgePad 512 model (median) | 0.94 to 1.32 ms | 1.04 ms |
| VDA engine build, cold | 196 s (step) + 8 s (cold start) | the same, with CUDA serving meanwhile |
| EdgePad 512 engine build, cold | 127 s | the same, with CUDA serving meanwhile |
| Load with cached engines | VDA 1.7 s, EdgePad 0.5 s | |

TensorRT takes each graph whole (one engine per graph, no nodes left for
the CUDA provider, which would need the cuDNN parts left out).

**Code changes made for this** (uncommitted):
- `onnx::cuda_backend_present()` reports whether cuDNN's ops library loads.
- Without it, the depth loader skips the CUDA load and builds on TensorRT
  straight away, and a TensorRT failure counts as the model failing, so
  VDA falls back to EdgePad.
- `--replay` waits through a TensorRT-only build.
- With the full development venv, nothing changes: CUDA first, then
  TensorRT.

**What the user sees:** host depth starts when the first engine is built,
about 3.5 minutes for VDA on a 3090, and about 2 minutes for EdgePad if
they switch to it. Meanwhile the Quest uses on-device depth, and the tray
needs to say so (Phase 3). Later starts take under 2 seconds.

**NVIDIA licences** (the texts in each wheel's `dist-info`):
- **CUDA EULA:** Attachment A lists `libcudart.so`, `libcublas.so`,
  `libcublasLt.so` and `libcurand.so` as distributable.
- **cuDNN:** "the runtime files .so" are distributable, inside an
  application with material additional functionality.
- **TensorRT:** the supplement grants distribution of "the libnvinfer and
  libnvinfer_plugin libraries", in binary form, as part of an application
  with material additional functionality.
  - `libnvonnxparser` is built from the open-source onnx-tensorrt project
    (Apache-2.0).
  - The builder resource files aren't named. They're `libnvinfer`'s
    per-GPU parts (split out in TensorRT 10), but the text doesn't say so.
  - Before release, ask nvidia-compute-license-questions@nvidia.com to
    confirm the builder resources are covered. Otherwise, the fallback is
    a first-run download of them.
- Each set of terms needs its licence text shipped and passed on to users
  (THIRD_PARTY_NOTICES, Phase 2).

## Native TensorRT spike (2026-10-07)

Can Meteor drop ONNX Runtime and call TensorRT directly? Tested with the
TensorRT Python bindings in an isolated folder holding only `libnvinfer`,
`libnvonnxparser`, `libnvinfer_plugin` (linked by the bindings, not needed
by Meteor) and the sm86 builder resource. GPU memory, streams and events
came from the CUDA driver API, so no cudart. Script:
`meteor/tools/trt_spike.py`.

**It works.** TensorRT built and ran the VDA step, the VDA cold start and
EdgePad 512 with nothing else:
- Running an engine loads only `libnvinfer`.
- A build adds the GPU's builder resource.
- TensorRT also looks for NVRTC and `libnvcuextend` (a driver file), and
  carries on without them. The engines built without NVRTC are as fast as
  those built with it.

**Speed (RTX 3090, VDA step, median):**

| | Time |
| --- | --- |
| ORT's own cached engine, run directly (spike) | 3.12 ms |
| Native build, fp32 inputs (spike) | 3.16 ms |
| Native build, fp16 inputs and outputs (spike) | 3.05 to 3.10 ms |
| EdgePad 512, native build (spike) | 0.79 ms |

Correction: the 5.03 ms first quoted for ONNX Runtime came from a noisy
replay. Back-to-back 120 fps replays of the same clip give 3.44 to
3.47 ms through ONNX Runtime and 3.14 to 3.17 ms native. ONNX Runtime
costs about 0.3 ms a step, so the native path is mostly about size.

fp16 inputs barely change the model's time. They would halve the caches
Meteor copies in every step (113 MiB to 57 MiB); the state pool is already
f16, so `vda_pack` would become a plain gather.

**Download size, per GPU:** NVIDIA's package server
(`pypi.nvidia.com`) answers HTTP range requests, so Meteor can fetch single
files out of the 3.7 GB TensorRT wheel. Compressed sizes in the wheel:

| File | Download |
| --- | --- |
| `libnvinfer.so.10` | 308 MB |
| `libnvonnxparser.so.10` | 2 MB |
| Builder resource: sm75 / sm86 / sm89 / sm120 | 94 / 152 / 161 / 235 MB |

About 400 to 550 MB of NVIDIA files per GPU, against 1.67 GiB for the fat
bundle. Fetched from NVIDIA's own server, they're never redistributed by
us, which settles the licence question for the default release.

**What a native backend needs in Meteor:**
- A small C++ shim (built with the `cc` crate) against TensorRT's headers,
  which are Apache-2.0 in NVIDIA's open-source TensorRT repository
  (`release/10.16`, `include/`).
- The shim opens `libnvinfer` at run time and calls its exported factory
  functions; the rest of the API is virtual calls. So Meteor still builds,
  and runs as a plain proxy, without TensorRT.
- The shim has to: parse the ONNX file; build the engine (fp16, opt level 4
  for the step, fp32 opt 0 for the cold start); save and load plans in the
  existing cache folders; bind Meteor's device pointers; and enqueue on
  Meteor's CUDA stream.

Not checked yet: VDA parity through the native engines (the spike timed
zeroed inputs), and the cold start built at fp32 opt 0 as Meteor does (the
spike built it at fp16 opt 4).

### Native TensorRT backend for VDA (built 2026-10-07, uncommitted)

VDA now runs on TensorRT without ONNX Runtime whenever `libnvinfer` and
`libnvonnxparser` open. `METEOR_TENSORRT=ort` switches back to ONNX
Runtime's TensorRT provider. ONNX Runtime stays for EdgePad and for the CUDA
fallback until the Vulkan backend replaces it.

- **Code:**
  - `native/tensorrt.cpp`: the shim, a C API over TensorRT's C++
    interfaces, built by `build.rs` with the `cc` crate.
  - `src/tensorrt.rs`: the safe wrapper.
  - `third_party/tensorrt/`: NVIDIA's Apache-2.0 headers, plus a two-line
    stand-in for `cuda_runtime_api.h`, so no CUDA toolkit is needed.
- **Graphs:** a VDA graph is now `Runner::Ort` or `Runner::Native`.
  - Native graphs own their outputs and a CUDA stream (new
    `cuStreamCreate`/`Destroy`/`Synchronize` in `nvdec::Api`).
  - They are released in the pushed context when the model drops.
- **Plans:** cached as `native.plan` (with `native.timing`, the timing
  cache) in the same engine folders as ONNX Runtime's engines. The folder
  name includes the TensorRT version and the GPU.
- **Engine builds run in a child process,** `nightfall-meteor
  --build-tensorrt <onnx> <plan> <timing> <fp16|fp32> <level>`.
  - Building in Meteor's own process leaves TensorRT in a state where the
    freshly built VDA step engine gives non-finite depth on its first run.
    The same plan loaded in a fresh process is fine. Reproduced twice;
    rebuilding only the cold start in-process didn't trigger it.
  - A child also returns the builder's memory on exit, and a builder crash
    can't take down the proxy.
- **Results on the RTX 3090:**

  | | ORT TensorRT | Native |
  | --- | --- | --- |
  | Parity, model inputs (correlation mean / worst) | 0.999945 / 0.999733 | 0.999951 / 0.999653 |
  | Parity, 720p frames (mean / worst) | 0.999510 / 0.999158 | 0.999514 / 0.999154 |
  | Step, 120 fps replay | 3.44 to 3.47 ms | 3.14 to 3.17 ms |
  | Frame to map, 120 fps replay | 5.6 ms | 5.3 ms |
  | Load from cache | 1.4 s | 0.3 s |
  | Step engine build from scratch | 196 s | 172 s |

  Parity is against the researcher's reference sequence
  (`vda::tests::reference_sequence_parity`, 75 frames).

## Vulkan EdgePad spike (2026-10-07)

Can EdgePad 512 run without any NVIDIA inference library, so the small
AppImage works with no download? Tested with ncnn (Vulkan compute, BSD-3)
from its Python wheel on the RTX 3090.

**Conversion:** `pnnx zipdepth_wide_512x288.onnx inputshape=[1,3,288,512]
fp16=0`.
- pnnx can't map ONNX `DepthToSpace`, so it leaves an unknown layer.
- ncnn's `PixelShuffle` with `1=1` (DCR mode) is the same operation. One
  line in the `.param` file: `PixelShuffle DepthToSpace_148 1 1 168 169
  0=2 1=1`.
- `fp16=0` keeps the weights in fp32 (24.6 MB). The default fp16 weights
  add error.
- The converted model comes from the ZipDepth export, so the conversion
  belongs with the model tooling. Check with the model owner before adding
  it there.

**Parity:** 30 real frames (a 2560x1440 game capture, every 80th frame,
scaled to 512x288). Error is measured against ONNX Runtime CUDA fp32, as
a percentage of the depth range:

| Backend | Mean | p99 | Max | Time per frame |
| --- | --- | --- | --- | --- |
| TensorRT fp16 (today's production path) | 0.068% | 0.27% | 0.85% | |
| ncnn Vulkan fp32 | 0.010% | 0.05% | 0.16% | 3.0 to 3.5 ms |
| **ncnn Vulkan, fp16 storage, fp32 arithmetic** | **0.061%** | **0.21%** | **0.72%** | **2.4 to 2.7 ms** |
| ncnn Vulkan, fp16 storage and arithmetic | 0.158% | 0.55% | 1.60% | 2.3 to 2.6 ms |

- **fp16 storage with fp32 arithmetic** matches TensorRT fp16's accuracy.
- **Times** are wall time from Python, including the upload of the input
  and the download of the depth. That's well inside the 8.3 ms of a
  120 Hz frame, though slower than TensorRT's 0.8 ms.
- **The fp32 result** shows the conversion is exact.

**Size:**
- ncnn's library is 21 MB, with glslang built in. It needs only the
  system's Vulkan loader, which every NVIDIA driver install provides.
- Meteor (6.5 MB), ncnn and the fp32 EdgePad weights compress to about
  **32 MB**.

**In Meteor:**
- ncnn has a C API (`c_api.h`), so the Rust side is a thin FFI, built
  from source with the `cc`/`cmake` crate, or linked as a prebuilt static
  library.
- Frames are prepared by CUDA. The 512x288 input (1.8 MB as fp32) goes
  through host memory into Vulkan, and the depth (0.6 MB) comes back the
  same way, a fraction of a millisecond each. CUDA–Vulkan external-memory
  interop can replace the copies later if they show up in the timings.
- Vulkan isn't tied to NVIDIA, which matters once decoding stops being
  NVDEC-only (meteor-windows.md, other GPUs).

## Direction (2026-10-07)

From the two spikes:

| Release | Contents | Size |
| --- | --- | --- |
| **Default: small AppImage** | Meteor, ncnn, EdgePad 512 (Vulkan) | about 32 MB |
| VDA, downloaded on first use | `libnvinfer`, the ONNX parser and this GPU's builder resource, from `pypi.nvidia.com` by HTTP range request; the VDA graphs from our release | about 400 to 550 MB of NVIDIA files, plus VDA |
| Optional: offline AppImage | Everything above for all four GPU generations | to measure; under the 1.67 GiB of the ONNX Runtime bundle |

ONNX Runtime goes: EdgePad runs on ncnn, VDA on native TensorRT. Engines
are built locally and cached as today. While VDA downloads and builds,
EdgePad serves depth. The phases below assume the fat ONNX Runtime bundle
and need rewriting for this.

## Phase 1: make Meteor relocatable

Today Meteor finds its runtime only in the development folder, and its
models only in `~/.local/share/nightfall-meteor/models`.

- **Runtime discovery** (`onnx.rs`): in order, `onnxruntime_lib` from
  `meteor.toml`, the AppImage's runtime folder (`$APPDIR/usr/lib/meteor`),
  then the development venv (`target/bench-venv`, as today).
- **Library loading:** the AppRun sets `LD_LIBRARY_PATH` to the runtime
  folder, so ONNX Runtime and TensorRT find their libraries by soname.
  `preload_cuda_libraries()` then only covers the development venv's pip
  layout, or goes away.
- **Bundled models** (`depth.rs`): the Model menu lists the bundled folder
  (`$APPDIR/usr/share/nightfall-meteor/models`) and the user's models
  folder. A user's file of the same name wins, so a newer model can replace
  a bundled one without rebuilding the AppImage.
- **Defaults:** VDA when its two files are present, else EdgePad 512. Depth
  smoothing defaults to off for VDA and on for the EdgePad models (VDA is
  temporally steady without it, and it adds about 40 ms of lag). The
  default is per model, so switching models doesn't carry the other
  model's choice; once the user sets it, their choice is saved.
- **The TensorRT cache** stays in `~/.cache/nightfall-meteor/tensorrt`. Its
  key (model hash, precision, builder settings, TensorRT version, GPU)
  already rebuilds engines after a driver or AppImage update that changes
  TensorRT.

## Phase 2: build the AppImage

`meteor/tools/build_appimage.sh`, run in a container so the result works on
older distributions:

1. Build `nightfall-meteor` (release) in an older base, e.g. Ubuntu 22.04
   (glibc 2.35). NVIDIA's wheels need glibc 2.28 or newer, so that's the
   real floor. No CUDA toolkit is needed: the kernels are prebuilt PTX.
2. Download pinned wheels with hashes: `onnxruntime-gpu` 1.30.x,
   `tensorrt-cu13` 10.16.1 (Meteor's ONNX Runtime links TensorRT 10), and
   the cuDNN, cuBLAS, cuRAND and cudart wheels it was tested with. Unpack
   only the Phase 0 file list into `AppDir/usr/lib/meteor`.
3. Copy the three model files into `AppDir/usr/share/nightfall-meteor/models`
   and check their SHA-256s (VDA's are already in `vda.rs`).
4. Add the AppRun, a `.desktop` file, the tray icon as a PNG, and
   `THIRD_PARTY_NOTICES` (ONNX Runtime MIT, VDA-S Apache-2.0, ZipDepth MIT,
   the NVIDIA licence texts).
5. Pack with appimagetool (zstd), embedding update information for
   AppImageUpdate (`gh-releases-zsync`), so updates can download only the
   changed blocks later.
6. Fail if the result is over 1.9 GiB.

The repository's client AppImage (`tools/build_support/build_linux.sh`)
already fetches appimagetool; reuse that step.

## Phase 3: first run

What the user sees, and what Meteor has to do for it:

- **Autostart:** on first run, Meteor writes
  `~/.config/autostart/nightfall-meteor.desktop` pointing at `$APPIMAGE`
  (the AppImage's own path), and the tray gets a "Start with my computer"
  toggle. On every start, if autostart is on and the AppImage has moved,
  Meteor rewrites the path.
- **Engine build status:** while TensorRT engines build, the tray shows
  "Preparing depth for your GPU" with the model name, instead of a model
  that isn't ready. When it's done, the status shows the model as usual.
- **Sunshine not running:** Meteor already waits for it and reports its
  status. The tray says "Waiting for Sunshine".
- **Firewall:** Meteor needs TCP 47900, 47901, 48984, 48989 and 49010, and
  UDP 47902 and 48998 to 49002. If the ports are blocked, the Quest can't
  find Meteor and silently uses on-device depth, so this has to be visible:
  - On start, check firewalld (the active zone's ports and services) and
    ufw if present.
  - If any port is blocked, the tray shows "Firewall is blocking the Quest"
    with an "Allow" item that runs one `pkexec firewall-cmd --permanent ...`
    (or `ufw allow`) command, then reloads.
  - Fedora's Workstation zone (1025 to 65535 open) passes without a prompt.
- **Logs:** an autostarted AppImage has no terminal, so Meteor also logs to
  `~/.local/state/nightfall-meteor/meteor.log` (rotated at a few MB). The
  tray gets "Open log".
- **Second launch:** today it logs "is Meteor already running?" and exits.
  Show a desktop notification instead ("Meteor is already running; it's
  in the tray").
- **No tray host** (GNOME without the AppIndicator extension): Meteor still
  runs. Detect the missing StatusNotifierWatcher and send one notification
  saying Meteor is running and that the AppIndicator extension adds its
  controls.

## Phase 4: fix the shutdown crash

Meteor often exits with SIGSEGV (exit code 139) when stopped. That matters
more with autostart: every logout or shutdown would leave a crash report.
Likely candidates: CUDA or TensorRT objects freed after the context, or
ONNX Runtime sessions dropped while the depth thread is still running.
Reproduce with `kill -TERM` during a replay, get a backtrace (core dump or
gdb), and make shutdown stop the depth thread and drop the models before
the process exits.

## Phase 5: test and release

Test on a clean account each time: a new Linux user on the development
machine, so `~/.config`, `~/.cache` and `~/.local` start empty.

| Check | Expect |
| --- | --- |
| Run on Bazzite / Fedora Atomic (KDE) | Tray, autostart entry, VDA engines build, the Quest gets VDA depth |
| Run on an Ubuntu 22.04 or 24.04 distrobox with the host driver | Starts, loads the runtime, builds the engines |
| GNOME without AppIndicator | The notification; Meteor still serves depth |
| Firewall: firewalld public zone | The tray warns; "Allow" opens the ports and the Quest finds Meteor |
| Second launch | The notification, one instance |
| Move the AppImage, log in again | Autostart follows it |
| Logout / shutdown | Clean exit, no crash report |
| GPUs | At least one of RTX 20, 30, 40, 50 each, ideally; the builder resources differ per generation |
| Size | Under 1.9 GiB |

Release: a GitHub release asset, with the SHA-256 in the release notes and
a short install section in `meteor/README.md` (make executable, run; what
the tray items do; where config, logs and models live).

## Risks

| Risk | Mitigation |
| --- | --- |
| Over 2 GiB | Phase 0; the build fails above 1.9 GiB |
| A future model needs a node TensorRT can't take | The CUDA provider would run it and need cuDNN's ops; check each new model on the trimmed runtime (one engine per graph) |
| NVIDIA's licences don't allow redistributing a file | Check before Phase 2; if a file can't ship, it becomes a first-run download from NVIDIA's own servers |
| A newer driver changes engine compatibility | The cache key includes the TensorRT version and GPU; add the driver version too |
| A distribution's glibc is too old | Build on Ubuntu 22.04; NVIDIA's wheels need 2.28 anyway |
| FUSE missing (some minimal installs) | The AppImage runtime's own error message; `--appimage-extract-and-run` documented in the README |
| First-run wait for engines is confusing | The tray status; the Quest keeps on-device depth meanwhile |

## Open questions

- Do the TensorRT terms cover the builder resource files? (Ask NVIDIA.)
- How long do the VDA and EdgePad engine builds take on RTX 20 and 40
  cards (only the 3090 is measured: VDA about 2.5 minutes)?
- Should Meteor build the engines in the background on first run even when
  no Quest is connected, so the first stream already has VDA? (Proposed:
  yes, at low priority.)
