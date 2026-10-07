# Nightfall Meteor: AppImage

> Status: Phase 0, the native TensorRT backend for VDA, the Vulkan EdgePad
> backend, Phase 1 and Phase 2 done (2026-10-07; Phase 2 needs the graphs'
> release and NVIDIA's answer); Phases 3 to 6 planned for a small AppImage
> with VDA downloaded on first use (rewritten 2026-10-07).
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
2. A tray icon appears. Meteor finds Sunshine, starts EdgePad 512 on Vulkan
   straight away, and adds itself to autostart.
3. The Quest finds Meteor the next time it connects to that PC and uses host
   depth. Nothing changes on the headset.
4. Video Depth Anything (VDA) is in the Model menu as a download. Choosing
   it downloads TensorRT from NVIDIA and the VDA graphs, builds the engines
   for this GPU, and switches to VDA. EdgePad serves depth meanwhile.

The user installs only the NVIDIA driver and Sunshine (or a fork), as they
already would to stream.

## Decisions

1. **Small AppImage** (revised 2026-10-07; the first version of this plan
   bundled the whole ONNX Runtime GPU runtime at 1.67 GiB). It holds
   Meteor, ncnn and EdgePad 512 converted for ncnn: about 32 MB. No
   ONNX Runtime and no NVIDIA inference libraries.
2. **VDA is a download, on request.** Choosing it in the Model menu is the
   user's go-ahead. TensorRT's files come from NVIDIA's own server
   (`pypi.nvidia.com`), only the ones this GPU needs; the VDA graphs come
   from our release.
3. **EdgePad 512 by default.** Once VDA is installed and chosen, it stays
   the choice (state.toml), and EdgePad is its fallback, as today.
4. **ONNX Runtime leaves the release build.** EdgePad runs on ncnn and VDA
   on native TensorRT. The ONNX Runtime code stays for development
   comparisons behind a cargo feature until the AppImage ships, then goes.
5. **Autostart on by default**, with a tray toggle to turn it off. Running
   the AppImage is taken as the user's intent to use Meteor.
6. **An offline AppImage** (VDA and TensorRT for the four consumer GPU
   generations inside) only if users ask for one.

## The size limit

This was the fat AppImage's problem; it's kept for the offline AppImage.
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

### Native TensorRT backend for VDA (built 2026-10-07)

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
- Only Meteor uses the ncnn format (the Quest runs TFLite), and Meteor may
  become its own repository, so the conversion lives in `meteor/models/`.
  It reads the ZipDepth ONNX export and leaves the ZipDepth tooling alone.
  The converted weights (24.6 MB) aren't committed; the AppImage build
  runs the conversion.

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

### Vulkan EdgePad backend (built 2026-10-07)

- **Runtime:** `src/ncnn.rs` opens ncnn's prebuilt shared library (release
  20260526, `ubuntu-2404-shared`, 20 MB, 8.7 MB zipped) through its C API.
  Like ONNX Runtime, it loads at run time, so Meteor builds and runs
  without it. Four GPU functions (create the instance, count devices, the
  default device, its name) come from ncnn's C++ API by their mangled
  names. `tools/fetch_ncnn.sh` downloads the library into `target/ncnn`.
- **Lookup:** `ncnn_lib` in meteor.toml, then next to the binary, `../lib`
  (the AppImage), `target/ncnn/lib`, then the library path.
- **Models:** `meteor/models/convert_ncnn.py` turns an ONNX export into
  `<name>.ncnn.param` and `.bin`. It does the `PixelShuffle` fix and
  records the input size on the `Input` layer. The weights aren't
  committed.
- **Menu:** each EdgePad model is listed once: on ncnn when it's converted
  and ncnn loaded, else as `.onnx` on ONNX Runtime. `METEOR_NCNN=off`
  prefers ONNX. A saved choice in the other format carries over.
- **No ONNX Runtime:** depth runs on ncnn alone, and VDA is hidden. Tested
  with a missing `onnxruntime_lib`: the only NVIDIA libraries loaded were
  the driver's `libcuda` and `libnvcuvid`.
- **Data path:** NVDEC still prepares the tensor in CUDA memory. It comes
  back to the CPU (1.8 MB), goes into ncnn, and the depth comes back for
  CPU post-processing.

| EdgePad 512, RTX 3090 | ncnn Vulkan | TensorRT fp16 (ONNX Runtime) |
| --- | --- | --- |
| Error vs ONNX Runtime CUDA fp32, mean / max | 0.061% / 0.72% | 0.068% / 0.85% |
| Model run back to back (median / p95) | 2.5 / 3.2 ms | |
| Replay at 120 fps: model step | 3.4 ms | 1.0 ms |
| Replay at 120 fps: post-processing | 0.9 ms (CPU) | 0.3 ms (GPU) |
| Replay at 120 fps: frame to map (median / p95) | 5.8-6.0 / 14-15 ms | 3.1 / 5.4 ms |
| Replay at 60 fps: model step | 3.9 ms | |
| Load | 0.8 s (3.4 s with a cold driver shader cache) | 0.25 s CUDA, then TensorRT |

Why the model step is slower in the replay than back to back:
- The GPU time-slices between NVDEC's CUDA context and Vulkan. TensorRT
  shares the CUDA context, so it doesn't switch.
- The GPU and CPU clock down between frames. The 60 fps replay is slower
  than the 120 fps one.

The cost is about 3 ms median and 9 ms at p95 against TensorRT. It's
acceptable for the no-download default. Later improvements:
- CUDA–Vulkan external memory, to drop the copies and allow GPU
  post-processing;
- EdgePad on native TensorRT once the VDA download is installed.

## Direction (2026-10-07)

From the two spikes:

| Release | Contents | Size |
| --- | --- | --- |
| **Default: small AppImage** | Meteor, ncnn, EdgePad 512 (Vulkan) | about 32 MB |
| VDA, downloaded on first use | `libnvinfer`, the ONNX parser and this GPU's builder resource, from `pypi.nvidia.com` by HTTP range request; the VDA graphs from our release | about 400 to 550 MB of NVIDIA files, plus VDA |
| Optional: offline AppImage | Everything above for all four GPU generations | to measure; under the 1.67 GiB of the ONNX Runtime bundle |

ONNX Runtime goes: EdgePad runs on ncnn, VDA on native TensorRT. Engines
are built locally and cached as today. While VDA downloads and builds,
EdgePad serves depth.

What a VDA download fetches, from `tensorrt_cu13_libs-10.16.1.11`
(manylinux_2_28 x86_64, 3.7 GB; the server answers range requests, so
only these members are read):

| File | Compressed | Installed |
| --- | --- | --- |
| `libnvinfer.so.10` | 308 MB | 663 MB |
| `libnvonnxparser.so.10` | 2 MB | 5 MB |
| Builder resource, RTX 20 (sm75) | 94 MB | 116 MB |
| Builder resource, RTX 30 (sm86) | 152 MB | 176 MB |
| Builder resource, RTX 40 (sm89) | 161 MB | 185 MB |
| Builder resource, RTX 50 (sm120) | 235 MB | 262 MB |
| VDA graphs (our release) | about 240 MB | 240 MB |

So 0.55 to 0.79 GB to download and 1.0 to 1.2 GB on disk, depending on
the GPU. The wheel also has sm80, sm90 and sm100 (data-centre parts) and a
PTX resource (215 MB) that may serve a GPU with no resource of its own.

## Phase 1: Meteor without ONNX Runtime (done, 2026-10-07)

- **TensorRT lookup** (`tensorrt.rs`): `libnvinfer` and the parser are
  opened by path from `tensorrt_dir` in meteor.toml, the VDA download's
  folder (`~/.local/share/nightfall-meteor/runtime/tensorrt-10.16.1`,
  `tensorrt::install_dir()`), or the development venv's `tensorrt_libs`;
  then by soname. TensorRT opens the builder resource from its own folder
  (its RPATH is `$ORIGIN`). The engine-build child no longer loads ONNX
  Runtime.
- **The `onnxruntime` cargo feature** (on by default):
  - `onnx.rs` keeps `Backend` and picks `onnx/runtime.rs` or a stub, whose
    `init()` fails and whose `DepthModel` can't exist;
  - VDA's ONNX Runtime graphs moved to `vda/ort_graph.rs`;
  - `ort` is an optional dependency;
  - `cargo build --no-default-features` builds Meteor without it, warning
    free.
- **VDA without ONNX Runtime:** it's listed when its graphs are there and
  TensorRT loads. With no CUDA provider to run it while the engines build,
  the preferred EdgePad model loads first and serves until VDA is ready.
  The status says VDA is loading.
- **Bundled models:** the menu also lists
  `<binary>/../share/nightfall-meteor/models`; a file of the same name in
  the user's folder wins.
- **Smoothing per model:** remembered per model in `state.toml`
  (`[model_smoothing]`). Unset, it's off for VDA and on for EdgePad.
  Older files' single `smoothing` switch is ignored. A unit test checks
  that an older file still parses, because reusing that key had made old
  files fail to parse and drop the saved model.

Tested on the RTX 3090 with the build without ONNX Runtime:
- **VDA from cached engines:** EdgePad loaded in 0.8 s and VDA took over
  0.8 s later.
- **From an empty cache:** EdgePad served while the child built both engines
  with the venv's TensorRT (cold start 7 s, step 182 s). Then VDA ran at
  5.1 ms frame to map (p95 5.3 ms), with no frames skipped.
- **Libraries loaded:** only the NVIDIA driver's own, Vulkan, ncnn and
  TensorRT's two libraries.

## Phase 2: the VDA download (built 2026-10-07)

Built in `src/download.rs`, with the tray items in `src/tray.rs` and
`nightfall-meteor --download-vda` for terminals and scripts.

- **In the tray:** while VDA can't run, the Model menu ends with a
  "Download Video Depth Anything (N MB)" submenu, with N for this GPU. It
  contains:
  - the reason to want it;
  - "Needs NVIDIA TensorRT, downloaded from NVIDIA under NVIDIA's licence";
  - a line about the one-off engine build (about 3 minutes);
  - "Read NVIDIA's TensorRT licence", which opens the licence page;
  - "Accept and download".

  While the download runs, the menu shows "Downloading VDA: X of Y MB" and
  "Cancel download". Afterwards Meteor switches to VDA; the current model
  serves while VDA's engines build. A failed download shows its reason in
  the submenu, and the user can try again. "Remove the VDA download"
  deletes TensorRT, the graphs it fetched (listed in
  `downloaded-models.txt`) and VDA's cached engines.
- **Choosing the files:** compute capability 7.5, 8.0, 8.6, 8.9, 9.0, 10.0
  and 12.0 each have a builder resource. Any other GPU gets no offer;
  `--download-vda` says why.
- **Fetching:**
  - `ureq` (rustls, bundled roots) and `flate2`;
  - two range requests read the wheel's zip64 central directory, then each
    member's bytes, inflated as they stream in;
  - SHA-256s are pinned from the wheel's `RECORD`, and were checked against
    the pip-installed files;
  - each file is written as `.partial` and renamed only once its hash
    matches;
  - `libnvinfer` goes last, so a half-done download never looks
    installed;
  - a free-space check runs first.
- **TensorRT reloads without a restart:** `tensorrt::init()` no longer
  remembers a failure, so the download's folder is found as soon as it's
  complete.

Tested 2026-10-07 in an AppImage-like layout on the RTX 3090, with the
build without ONNX Runtime, empty config, data and cache folders, and the
bundled EdgePad:
- the download fetched 701 MB in 24 s: 462 MB from NVIDIA, and the graphs
  from a local server;
- every hash matched;
- the bundled EdgePad loaded first. The child built VDA's engines from
  the downloaded TensorRT (7 s and 167 s); nothing else NVIDIA was loaded
  beyond the driver.
- VDA then ran at 5.1 ms frame to map (p95 5.3 ms) with no frames skipped.

Still to do:
- **Hosting the graphs:** `VDA_URL` points at a release that doesn't exist
  yet (`meteor-vda-s-518x294` on tB0nE/nightfall). Creating it and
  uploading the two graphs (Apache-2.0, with their licence) is the
  maintainer's step.
- **NVIDIA's answer** on fetching the wheel's files this way (Open
  questions).
- **Updates:** a newer TensorRT downloads into a new folder; removing the
  old one once the new one works isn't written yet.
- **Resuming within a file**, and reading the package index for the file
  name if the pinned URL moves: not done. An interrupted download restarts
  the file it was on.

## Phase 3: build the AppImage

`meteor/tools/build_appimage.sh`, run in a container so the result works on
older distributions:

1. Build `nightfall-meteor` (release, without the `onnxruntime` feature) on
   Ubuntu 22.04 (glibc 2.35). The TensorRT wheel needs glibc 2.28, so that
   is the floor for VDA. No CUDA toolkit is needed: the kernels are
   prebuilt PTX and the TensorRT headers are vendored.
2. Fetch ncnn's `ubuntu-2204-shared` build (the 24.04 build needs glibc
   2.39), pinned by version and SHA-256, into `AppDir/usr/lib`. It needs
   `libgomp`, which goes in too.
3. Convert EdgePad 512 with `models/convert_ncnn.py` from the pinned ONNX
   export, check it with the parity test, and put it in
   `AppDir/usr/share/nightfall-meteor/models`.
4. Add the AppRun, a `.desktop` file, the tray icon as a PNG, and
   `THIRD_PARTY_NOTICES` (ncnn BSD-3, the TensorRT headers Apache-2.0,
   ZipDepth MIT; VDA-S Apache-2.0 and NVIDIA's licence for the download).
5. Pack with appimagetool (zstd), embedding update information for
   AppImageUpdate (`gh-releases-zsync`).
6. Fail if the result is over 100 MB.

The repository's client AppImage (`tools/build_support/build_linux.sh`)
already fetches appimagetool; reuse that step. The VDA graphs go up as
separate assets on the same release.

## Phase 4: first run

What the user sees, and what Meteor has to do for it:

- **Autostart:** on first run, Meteor writes
  `~/.config/autostart/nightfall-meteor.desktop` pointing at `$APPIMAGE`
  (the AppImage's own path), and the tray gets a "Start with my computer"
  toggle. On every start, if autostart is on and the AppImage has moved,
  Meteor rewrites the path.
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
  tray gets "Open log". ncnn prints its GPU list to stderr at start; that
  goes to the log too.
- **Second launch:** today it logs "is Meteor already running?" and exits.
  Show a desktop notification instead ("Meteor is already running; it's
  in the tray").
- **No tray host** (GNOME without the AppIndicator extension): Meteor still
  runs on EdgePad. Detect the missing StatusNotifierWatcher and send one
  notification saying Meteor is running and that the AppIndicator
  extension adds its controls (including the VDA download).

## Phase 5: fix the shutdown crash

Meteor often exits with SIGSEGV (exit code 139) when stopped. That matters
more with autostart: every logout or shutdown would leave a crash report.
Likely candidates: CUDA or TensorRT objects freed after the context, the
ncnn Vulkan instance torn down by a static destructor while a net still
exists, or models dropped while the depth thread is still running.
Reproduce with `kill -TERM` during a replay, get a backtrace (core dump or
gdb), and make shutdown stop the depth thread and drop the models before
the process exits.

## Phase 6: test and release

Test on a clean account each time: a new Linux user on the development
machine, so `~/.config`, `~/.cache` and `~/.local` start empty.

| Check | Expect |
| --- | --- |
| Run on Bazzite / Fedora Atomic (KDE) | Tray, autostart entry, EdgePad on Vulkan within seconds, the Quest gets depth |
| Choose VDA | Download with progress, engine build, then VDA; EdgePad throughout |
| Interrupt the download (network off, quit) | Resumes or restarts cleanly; never half-installed |
| Run on an Ubuntu 22.04 or 24.04 distrobox with the host driver | Starts on EdgePad; VDA downloads and builds |
| GNOME without AppIndicator | The notification; Meteor still serves depth |
| Firewall: firewalld public zone | The tray warns; "Allow" opens the ports and the Quest finds Meteor |
| Second launch | The notification, one instance |
| Move the AppImage, log in again | Autostart follows it |
| Logout / shutdown | Clean exit, no crash report |
| GPUs | At least one of RTX 20, 30, 40, 50 each, ideally: the builder resources differ per generation, and Vulkan performance differs |
| Size | Under 100 MB |

Release: a GitHub release with the AppImage and the VDA graphs, SHA-256s in
the release notes, and a short install section in `meteor/README.md` (make
executable, run; what the tray items do; where config, logs, models and
the VDA download live).

## Risks

| Risk | Mitigation |
| --- | --- |
| NVIDIA moves or removes the wheel | Pinned URL and hashes; EdgePad keeps working; an index lookup as fallback; a Meteor update fixes it |
| NVIDIA's terms don't allow fetching the wheel's files this way | Ask before Phase 2 (below); the fallback is the offline AppImage or asking users to install TensorRT themselves |
| A future model needs a layer ncnn doesn't have | Meteor's load fails with ncnn's message, and the ONNX model still works in development; check each retrained model with the parity test |
| ncnn is slower than TensorRT for EdgePad (5.9 against 3.1 ms frame to map on a 3090; p95 14 against 5 ms) | Acceptable for the default; CUDA–Vulkan external memory, or EdgePad on TensorRT once VDA's download is there |
| A Vulkan driver problem on some systems | ncnn picks the discrete GPU and logs it; if Vulkan fails, depth is off with the reason in the tray, and VDA (TensorRT) still works once installed |
| A newer driver changes engine compatibility | The cache key includes the TensorRT version and GPU; add the driver version too |
| A distribution's glibc is too old | Build on Ubuntu 22.04 with ncnn's 22.04 build; TensorRT needs 2.28 anyway |
| FUSE missing (some minimal installs) | The AppImage runtime's own error message; `--appimage-extract-and-run` documented in the README |
| First-run wait for VDA is confusing | Download and build progress in the tray; EdgePad serves meanwhile |

## Open questions

- Does NVIDIA's licence allow an application to fetch individual files
  from the TensorRT wheel on the user's behalf, and does the user need to
  accept it first? Ask nvidia-compute-license-questions@nvidia.com, along
  with the builder resources question.
- How long do the VDA engine builds take on RTX 20 and 40 cards (only the
  3090 is measured: about 3 minutes), and how fast is ncnn EdgePad on them?
- Is the PTX builder resource enough for a GPU without its own?
- Should a GPU without NVDEC (or a non-NVIDIA GPU) get anything? Decoding
  is NVDEC-only today, so not yet (meteor-windows.md has the decoding
  options).
