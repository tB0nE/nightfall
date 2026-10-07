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
