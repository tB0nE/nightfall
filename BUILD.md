# Building Nightfall

## Prerequisites

- **Godot 4.7 stable** (editor + custom export templates)
- **Android SDK platform 36 and Build Tools 36.1.0**
- **Android NDK 29.0.14206865**
- **JDK 17**
- **vcpkg** (for GDExtension dependency management)
- **Ninja** (build system, used by CMake)
- **ADB** (for Quest deployment)
- **Rust 1.92+ and the `aarch64-linux-android` target** for the optional browser
  filtering engine bundled in Android builds. Install the target with
  `rustup target add aarch64-linux-android`. `build.sh` builds the pinned native
  bridge automatically; blocking itself is opt-in and off by default.

## 0. Install Godot Plugins

Open the project in the Godot editor and install the **GodotOpenXRVendors** plugin from the Asset Library (or enable it in Project → Install Plugins). This provides Meta Quest OpenXR vendor extensions.
The Android export requires the plugin descriptor, matching arm64 native library,
and Meta AAR under `addons/godotopenxrvendors/`. The build now fails if any of
these are missing; an APK without them starts but cannot offer passthrough.

## 1. Build the GDExtension

The Nightfall streaming GDExtension is built from source within the project:

### Install vcpkg

```bash
git clone https://github.com/microsoft/vcpkg.git ~/Development/Personal/vcpkg
~/Development/Personal/vcpkg/bootstrap-vcpkg.sh
```

### Android (Quest) Build

```bash
cd <project-root>/addons/nightfall-stream

export VCPKG_ROOT=~/Development/Personal/vcpkg
export VCPKG_DEFAULT_TRIPLET=arm64-android
export ANDROID_NDK_HOME=/path/to/ndk/29.0.14206865
export ANDROID_ABI=arm64-v8a

cmake --preset android
ninja -C build/android
```

This produces `build/android/bin/android/libnightfall-stream.android.template_debug.arm64.so` and deploys it to the Godot addon directory automatically.

> **Important**: Use cmake + ninja. Manual clang++ compilation can produce a `.so` that depends on `libc++_shared.so` which isn't in the APK, causing `UnsatisfiedLinkError` crashes.

### Release Build

For release, rebuild with CMAKE_BUILD_TYPE=Release and strip:

```bash
cmake --preset android -DCMAKE_BUILD_TYPE=Release
ninja -C build/android
<path-to-ndk>/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip \
  --strip-debug build/android/bin/android/libnightfall-stream.android.template_release.arm64.so \
  -o <project-root>/addons/nightfall-stream/bin/android/libnightfall-stream.android.template_release.arm64.so
```

> **Size comparison**: Debug ~162MB, Release (stripped) ~35MB.

### Linux Build

**You MUST build in an Ubuntu 22.04 container** to target glibc 2.35. Building on a newer host (e.g. Fedora 42 = glibc 2.43) produces a .so that won't load on most distros. `build.sh --linux` and `build.sh --appimage` handle this automatically via `docker-build-linux.sh`.

```bash
# Automatic (recommended) — uses Docker if .so doesn't exist yet
./build.sh --appimage

# Manual Docker build
bash docker-build-linux.sh
```

`docker-build-linux.sh` builds in an Ubuntu 22.04 container (glibc 2.35) using the `Dockerfile.linux-build` image. It copies the source read-only into the container, builds, and copies the .so back to the host. The Docker image is cached after the first build, but expect the FIRST build to take noticeably longer than before (~15-20min, not ~5min) - see the TFLite note below.

To build on host without Docker (only if your host glibc ≤ 2.35, or you only target very new distros):

```bash
cd <project-root>/addons/nightfall-stream

export VCPKG_ROOT=~/Development/Personal/vcpkg
export VCPKG_DEFAULT_TRIPLET=x64-linux

cmake --preset linux -DCMAKE_BUILD_TYPE=Release
ninja -C build/linux-release
```

Either way, the output is `bin/linux/libnightfall-stream.linux.template_release.x86_64.so`. Linux AI 3D defaults to ZipDepth-384 through ncnn's Vulkan backend. The production selector keeps MiDaS-256 and Depth Anything V2-252 as CPU alternatives; older converted Vulkan variants remain development assets rather than user-facing choices. No vcpkg ports are used for these runtimes: `CMakeLists.txt` vendors TFLite `v2.17.0` and a pinned ncnn revision through `FetchContent`. The first configure therefore needs network access and is substantially slower; the Docker build cache preserves both source and compiled dependencies. Model files ship loose beside the binary in `depth_models/` rather than through Godot's PCK.

### Native OpenXR renderer (Quest/GLES)

Nightfall's fast presentation path is a separate GDExtension in
`extensions/nightfall-xr`. It samples MediaCodec's external OES texture
directly, renders both eyes into one double-wide OpenXR swapchain, and submits
two eye-specific sub-images through Godot's existing OpenXR frame loop. The
legacy Godot composition-layer path remains the automatic fallback for Linux,
multi-monitor layouts, raw/input depth diagnostic views, unsupported renderers,
and startup failures. DMap-Final and DMap-Warp remain on the native path so they
display the exact production depth and offset textures.

AI separation/convergence and Picture-tab brightness/contrast/gamma are
implemented directly in this path. Reactive ambient modes consume an
asynchronous 32x32 sample of its final left-eye output, so enabling ambient
lighting does not restore a full-resolution legacy video pass.
The Picture tab's Runtime sharpening modes also remain on this path and use
`XR_FB_composition_layer_settings`; percentage-based shader sharpening retains
the legacy fallback path for comparison and unsupported runtimes.

`build.sh` builds this extension automatically for Android. Prepare its pinned
toolchain once from the project root:

```bash
tools/build_support/bootstrap_native_xr.sh
```

The bootstrap clones immutable Godot and godot-cpp commits, applies all four
patches in order, builds a patched editor, generates matching OpenXR-aware C++
bindings, and builds both Android runtime variants. The output persists in the
ignored `.build-cache/native-xr/` directory instead of `/tmp`, so a reboot or
temporary-file cleanup does not break the next APK build. Use
`--sources-only` to validate the pinned revisions and patch set without doing
the long compilation.

The inputs are recorded in
`tools/build_support/native_xr_versions.sh`. The current pins are Godot
`5b4e0cb0fd279832bbdd69fed5354d4e5ad26f88` (4.7 stable), godot-cpp
`05057de73de4b99f114d36c40d84ca46926c0e25`, and Android NDK
`29.0.14206865`. Set `ANDROID_HOME` if the SDK is not in the default location.
The cache root and individual source trees can be overridden with
`NIGHTFALL_NATIVE_XR_CACHE`, `NIGHTFALL_GODOT_SOURCE`, and
`NIGHTFALL_GODOT_CPP`.

`build.sh` finds an editor named `godot` on `PATH` and otherwise retains the
historical local default. Override it with `NIGHTFALL_GODOT_EDITOR`. Export
templates are read from the standard XDG Godot data directory; use
`NIGHTFALL_GODOT_TEMPLATE_DIR` or `NIGHTFALL_ANDROID_SOURCE_TEMPLATE` for a
different installation. `NIGHTFALL_JAVA_HOME` selects JDK 17 when `JAVA_HOME`
is not already set.

To rebuild only the extension after bootstrapping:

```bash
extensions/nightfall-xr/build_android.sh debug
extensions/nightfall-xr/build_android.sh release
```

Debug and release builds now use matching godot-cpp and GDExtension targets.
The patched editor is only used to generate the custom bindings. APK export
continues to use the official 4.7 stable editor and `android_source.zip`, then
`build.sh` injects the matching cached patched runtime into the extracted
project.

### Patched Godot Engine (Quest only)

The Quest build uses a custom Godot engine. Its patches provide Vulkan Android Hardware Buffer (AHB) import support, projectionless OpenXR lifecycle support, and per-layer compositor filtering through `XR_FB_composition_layer_settings`. The compositor-filter patch exposes supersampling and sharpening controls on Godot's quad/cylinder composition-layer nodes; Nightfall uses the sharpening modes while retaining its shader implementation as a fallback.

The bootstrap command above is the supported way to create the patched engine.
For reference, it applies these source-controlled patches to the pinned Godot
commit:

- `godot-4.7-ahb.patch`
- `godot-4.7-projectionless.patch`
- `godot-4.7-projectionless-lifecycle.patch`
- `godot-4.7-compositor-filter.patch`

`build.sh` refuses to package an APK if the expected patched runtime is absent;
it no longer silently falls back to a stock runtime. An externally managed
runtime can be selected explicitly with `NIGHTFALL_GODOT_ANDROID_RUNTIME`.

## 2. Export the APK

The `build.sh` script handles everything:

```bash
# Debug build
./build.sh --debug

# Dev build: release-signed and optimized, for testing (requires .env)
./build.sh --dev

# Release build (requires .env with keystore credentials, and a version)
git tag v0.7.12 && ./build.sh --release
./build.sh --release --version 0.7.12   # before tagging
./build.sh --release --version 0.8.2-preview.1  # optimized prerelease

# Build and install via ADB
./build.sh --dev --install

# Linux AppImage
./build.sh --appimage
```

### Versions

`build.sh` writes the APK's `versionName` and `versionCode` at export time;
`export_presets.cfg` itself keeps placeholders. The code is
`MAJOR*10000 + MINOR*100 + PATCH`, so `0.7.12` is `712`.
Preview suffixes are kept in the version name but not the numeric code:
`0.8.2-preview.1` and `0.8.2` both use `802`, allowing in-place upgrades.

| Build | Version name | Version code |
| --- | --- | --- |
| `--release` | the release, from the `vX.Y.Z` tag on HEAD or `--version` | that release's |
| `--dev` | the last release tag plus the commit, e.g. `0.7.11-dev+66198ff` (`-dirty` with uncommitted changes) | the last release's |
| `--debug` | as dev, e.g. `0.7.11-debug+66198ff` | the last release's |

Dev builds share the last release's code, so each one installs over the
previous dev build and over that release, and the next release installs over
them. Android refuses to install a lower code over a higher one: going back to
an older release means uninstalling first, which also clears pairings and
settings. Debug builds are signed with the debug key, so they can't install
over a dev or release build without uninstalling either.

### WSL2 release build on Windows

On a WSL2 installation with the local build tools and caches under `.build-cache/`,
run `tools/build_support/build_release_wsl.sh` from the project root. It rebuilds
the release streaming GDExtension, builds a dev APK (or a release one, given
`--release` and the same version options as `build.sh`), then installs it
with Windows `adb.exe`. Windows ADB can reach a USB-connected Quest even when its
USB device is not passed through to WSL. The script expects the release keystore
configured in `.env`, the three Android EdgePad models in `models/`, and the Meta
plugin in `addons/godotopenxrvendors/`.

`.build-cache/` holds the canonical SDK, patched runtime and vcpkg checkout. The
script keeps fast working copies, plus the GDExtension build tree, in
`~/.cache/nightfall-build/` (override with `NIGHTFALL_WSL_CACHE`), seeding any
missing copy from `.build-cache/`. Because systemd clears `/tmp` on every WSL
boot, the `/tmp/nightfall-*` paths used by the builds are recreated as symlinks
into that directory on each run.

What `build.sh` does:
1. Builds the matching debug or release native OpenXR extension
2. Verifies and injects the cached patched Godot runtime
3. Wipes `android/build/` and extracts the Godot Android source template
4. Copies `GodotApp.java`, `DepthEstimator.java`, and stages the selected TFLite model
5. Verifies the custom LiteRT AAR checksum and patches the Gradle dependencies
6. Copies the Meta OpenXR vendor plugin AAR
7. Exports the APK via Godot headless
8. Cleans up `android/build/` and optionally installs via ADB

The compatibility entry point delegates focused work to scripts under
`tools/build_support/`: `build_android.sh` and `build_linux.sh` own platform
packaging, `package_android_models.sh` owns the Android model manifest, and
`deploy_android.sh` validates and installs an APK. The native-XR extension keeps
its own `extensions/nightfall-xr/build_android.sh` entry point.

For Linux AppImage (`--appimage`):
1. Builds Linux .so in Ubuntu 22.04 Docker container (glibc 2.35 compat, skips if .so already exists)
2. Exports the Linux PCK via Godot headless
3. Assembles Linux binary from release template + PCK
4. Creates AppDir with binary, PCK, .so files, plugin.gdextension, desktop entry, and icon
5. Builds AppImage via `appimagetool` (auto-downloaded to `/tmp/`)

### Depth models

Android bundles widescreen EdgePad-512, square EdgePad-256 and EdgePad-384 reference,
and two CPU models (EdgePad-256-CPU and EdgePad-384-CPU, for Backend: CPU).
Auto selects EdgePad-512/OpenCL on Quest 3/3S and EdgePad-256/OpenGL on
Quest 2, with EdgePad-256/OpenGL also used after an Auto OpenCL failure.
See `docs/guides/zipdepth-quest-tiers.md`. Retired EdgePad-320 and other research
exports remain in `models/`, but are not bundled. The models are published,
with their SHA-256s, in the
`edgepad-models-2026-10-08` release.
Linux bundles ncnn
Vulkan conversions of both ZipDepth models, MiDaS-256, MiDaS-192, and Depth
Anything V2-252, plus TFLite CPU variants of the latter three. The generated `.tflite` and
`.ncnn.*` files come from `models/` and are not committed, so the
platform-specific files must exist locally before building. See
**`models/README.md`** for the full manifest and acquisition/conversion notes;
the packaging scripts fail instead of silently shipping a missing model.

Depth Anything V2 and ZipDepth have reproducible conversion scripts (see
`models/README.md`):

```bash
# Requires: Python 3.12+ with PyTorch, onnx2tf, onnxsim
pip install onnx2tf sng4onnx onnxsim

python3 tools/convert_depth_anything_v2.py

# Quest GPU model. Builds the sharper standard/NPU hybrid by default.
python3 tools/convert_zipdepth.py --force

# Linux Vulkan model library; install pnnx or pass --pnnx /path/to/pnnx.
# Requires retained ZipDepth/Depth-Anything ONNX exports and MiDaS source/weights.
python3 tools/convert_linux_depth_ncnn.py --pnnx /path/to/pnnx
```

This downloads the Depth Anything V2 Small weights from HuggingFace, exports to
ONNX (196/252px input for the ViT-S patch-14 constraint), and converts to int8
quantized TFLite via `onnx2tf -kt input`. Output goes to `models/`.
ZipDepth's Adreno-safe graph rewrites and validation procedure are documented
in [`docs/guides/zipdepth-quest-gpu.md`](docs/guides/zipdepth-quest-gpu.md).

### Nightfall LiteRT GPU AAR

Normal Android builds use the checked-in `android/libs/litert-gpu-nightfall-1.4.2.aar`, a LiteRT 1.4.2 GPU delegate patched to select either a low-priority Qualcomm OpenCL context (`Stream`, the product default) or the driver's normal context (`AI 3D`) at runtime. Changing the AI 3D tab's GPU Priority setting recreates only the GPU delegate/interpreter; it does not restart the stream or app. Stream priority protects render and decode cadence during GPU-heavy games; AI 3D priority is an explicit opt-in for users who prefer maximum inference throughput.

For performance A/B testing, pass `--stock-litert` to use Google's unpatched `com.google.ai.edge.litert:litert-gpu:1.4.2` dependency instead:

```bash
./build.sh --release --stock-litert
```

To regenerate the patched AAR:

1. Check out TensorFlow 2.17.0 and apply `android/patches/litert-qcom-low-priority-opencl.patch`.
2. Configure Bazel 6.5.0 with Android NDK 25.2.9519653.
3. Build `//tensorflow/lite/java:libtensorflowlite_gpu_jni.so` with `--config=android_arm64`.
4. Replace `jni/arm64-v8a/libtensorflowlite_gpu_jni.so` in the official `com.google.ai.edge.litert:litert-gpu:1.4.2` AAR and remove its other ABI directories.

The JNI exports must match the official library before replacing the checked-in AAR.

### Nightfall Meteor

Meteor, the optional PC companion, builds separately with Cargo; see
[meteor/README.md](meteor/README.md). It needs Rust 1.92 and CMake (for the
Opus decoder it compiles from source). `meteor/tools/build_appimage.sh` builds
the Linux AppImage in a container, and `meteor/tools/build_windows_installer.ps1`
builds the Windows installer on Windows.

### Experimental Monado runtime probe

The current XR direction is a Meteor-managed Monado runtime, with WiVRn as a
streaming reference. Linux is the immediate spike; Windows remains a required
feasibility gate. See the [new plan](docs/plans/active/meteor-xr-monado-spike.md).

```bash
bash tools/build_support/probe_monado_runtime.sh --build
bash tools/build_support/probe_monado_runtime.sh --test
```

This pins source revisions, builds release binaries/dependencies in Docker, and
tests a separate service plus OpenXR app using a simulated HMD and a diagnostic
capture hook in the null compositor. The source pin stays clean; the hook is
applied to an output copy under `capture-source/`, built in `capture-build/`.
It sets `XR_RUNTIME_JSON` only inside the isolated test container, has no network
or GPU/device passthrough, and does not install/register a host runtime. Passing
means service/IPC/frame lifecycle and byte-matching stereo swapchain pixels
captured inside the service. It does not prove general composition, encoding or
XR streaming. The app and server PPM images remain available for inspection.
Artifacts and logs remain under `.build-cache/meteor-xr/monado-linux-spike/`.

For the separate **Linux/NVIDIA-only** Vulkan → CUDA → NVENC interop diagnostic:

```bash
bash tools/build_support/probe_vulkan_nvenc.sh
python3 test/test_nvenc_stereo_validator.py
```

Requires host Vulkan development headers/library, C++17 compiler, NVIDIA driver
with CUDA/NVENC, FFmpeg and Python. It uses SDK declarations from the pinned
WiVRn reference checkout (run the Monado build above first). No CUDA toolkit is
needed. Output is `.build-cache/meteor-xr/nvenc-spike/`: a five-frame H.264 stream,
decoded RGB and encoder log. The script fails rather than substituting software
encoding. This is an independent synthetic-image test, not yet Monado integration
or remote streaming. Its initial test pattern is uploaded once from the CPU;
the subsequent Vulkan → CUDA → NVENC handoff has no image readback. Only compressed
bitstream bytes return to the CPU. Tiny-frame timings are not XR benchmarks.

To test **actual Monado swapchains → GPU stereo packing → NVENC** on Linux/NVIDIA:

```bash
# Rebuild the diagnostic service/app after modifying the hook:
bash tools/build_support/probe_monado_runtime.sh --build
bash tools/build_support/probe_monado_nvenc.sh
```

This compiles a diagnostic encoder bridge and runs the built service/app natively
on the host GPU, not in the software-Vulkan container. It selects the NVIDIA ICD
and a generated runtime manifest only for its child processes, with a private
short `/tmp` IPC directory. It does not register a runtime or start SteamVR.
Host libraries must satisfy the container-built binaries (`ldd` can check).

Artifacts in `.build-cache/meteor-xr/monado-nvenc-spike/` include the H.264 output,
decoded RGB, per-frame pose/FOV/bitstream-range JSONL, app and service logs.
The test now submits 32 changing frames through one persistent encoder and one
reusable GPU surface. It checks every decoded marker, app-to-output monotonic
display timestamp, frame order and bitstream byte range, then verifies encoder
drain/resource release. The service pixel-readback branch must not run.

```bash
NIGHTFALL_XR_PROBE_FRAMES=120 bash tools/build_support/probe_monado_nvenc.sh
NIGHTFALL_XR_PROBE_ABORT=1 bash tools/build_support/probe_monado_nvenc.sh
```

The second command deliberately kills only the test OpenXR app after at least
five encoded frames to test disconnect cleanup. Runs overwrite only their known
diagnostic outputs. Frame count is 1–240 (at least 16 for the disconnect test).
This is a stop-and-wait correctness sequence with bounded single-frame
backpressure, not sustainable-rate/latency measurement. Asynchronous GPU fences,
realistic resolution/rate and transport remain outstanding.

To include **live diagnostic loopback frame transport** to a Rust receiver:

```bash
bash tools/build_support/probe_xr_transport.sh
NIGHTFALL_XR_PROBE_FRAMES=120 bash tools/build_support/probe_xr_transport.sh
NIGHTFALL_XR_PROBE_ABORT=1 bash tools/build_support/probe_xr_transport.sh
```

Requires `rustc` in addition to the Monado/NVENC prerequisites. This tests protocol
framing and native owned-packet delivery, then sends encoder output directly to
a loopback-only receiver, outside the Vulkan queue lock. No file-spool reads are
used in delivery; reference files remain for post-run comparison.
Every received payload, pose/FOV and timestamp must match, and received video is
decoded again for marker verification. It is not headset streaming or a
production asynchronous transport. No authentication/encryption; do not expose the diagnostic
port. See [wire format, limits and remaining work](docs/research/meteor-xr-transport-probe.md).

The previous spool sender remains available for regression comparison:

```bash
NIGHTFALL_XR_TRANSPORT_MODE=spool bash tools/build_support/probe_xr_transport.sh
```

Quest decoder/projection diagnostics (optimized DEV APK; ALVR remains OFF):

```bash
NIGHTFALL_PCVR_ALVR=OFF ./build.sh --dev --install
# Hardware decoder/ImageReader check only; does not enter XR:
bash tools/build_support/probe_android_xr_decoder.sh
# Arm this, then press the new DEV Meteor decoded stereo welcome button:
bash tools/build_support/probe_headset_xr_projection.sh
```

Both scripts require an ADB-authorized connected Quest and the existing Monado/
NVENC host prerequisites. Set `NIGHTFALL_ADB` for a non-default adb executable.
They use temporary USB-forwarded loopback sockets, not a LAN service. The decoder
check builds a standalone optimized NDK helper (same receiver as the app); the
projection check needs a person wearing the headset. Both are fixed-size SDR
patterns, **not tracked PCVR**. See [ownership, evidence and test steps](docs/research/meteor-xr-headset-decoder-spike.md).

For the next **tracked scene diagnostic**, rebuild the isolated Monado runtime
after changing its pinned patch, then run:

```bash
bash tools/build_support/probe_monado_runtime.sh --build
# No headset: moving synthetic poses through Monado/app + scene encode checks:
python3 test/run_monado_tracking_spike.py "$PWD"
# EXPERIMENT ONLY: free-running app with image leases; host-tested, not async:
NIGHTFALL_XR_FREE_RUNNING=1 python3 test/run_monado_tracking_spike.py "$PWD"
# Optional bounded worker delivery with a loopback receiver (host regression):
NIGHTFALL_XR_ASYNC_DELIVERY=1 NIGHTFALL_XR_FREE_RUNNING=1 \
  bash tools/build_support/probe_xr_transport.sh
# Optional raw encode worker as well (requires the previous two opt-ins):
NIGHTFALL_XR_ASYNC_ENCODE=1 NIGHTFALL_XR_ASYNC_DELIVERY=1 \
  NIGHTFALL_XR_FREE_RUNNING=1 bash tools/build_support/probe_xr_transport.sh
# Larger diagnostic profile (target Hz is not a sustained-rate guarantee):
NIGHTFALL_XR_EYE_SIZE=512 NIGHTFALL_XR_TARGET_HZ=60 \
  NIGHTFALL_XR_ASYNC_ENCODE=1 NIGHTFALL_XR_ASYNC_DELIVERY=1 \
  NIGHTFALL_XR_FREE_RUNNING=1 bash tools/build_support/probe_xr_transport.sh
# With the latest optimized DEV APK: arm, then press DEV: Meteor decoded stereo.
bash tools/build_support/probe_headset_xr_tracking_runtime.sh
# GPU scene correctness check (still includes CPU oracle and readback):
NIGHTFALL_XR_GPU_SCENE=1 NIGHTFALL_XR_EYE_SIZE=512 \
  NIGHTFALL_XR_TARGET_HZ=60 python3 test/run_monado_tracking_spike.py "$PWD"
# GPU scene measurement: no app pixel oracle/readback; timestamp queries + fences:
NIGHTFALL_XR_GPU_MEASURE=1 NIGHTFALL_XR_GPU_SCENE=1 \
  NIGHTFALL_XR_EYE_SIZE=512 NIGHTFALL_XR_TARGET_HZ=60 \
  NIGHTFALL_XR_ASYNC_ENCODE=1 NIGHTFALL_XR_ASYNC_DELIVERY=1 \
  NIGHTFALL_XR_FREE_RUNNING=1 python3 test/run_monado_tracking_spike.py "$PWD"
```

The tracked fixture keeps a separate USB tracking channel live while rendering
three spheres and a floor. It carries the host render poses/FOV in an explicitly
adopted Quest LOCAL origin, not Monado's startup-recentered LOCAL. This is a tiny
CPU-reference scene with hardware video encoding/decoding, not a performance
benchmark, game-ready stream or normal Meteor feature. Visual world-lock and
orientation need headset testing. See the [tracking report](docs/research/meteor-xr-tracking-spike.md).
The optional [GPU scene](docs/research/meteor-xr-gpu-scene.md) uses a Vulkan
compute shader built with the runtime probe. It retains CPU oracle/readback
validation by default. Its explicit measurement mode removes those checks and
reports GPU timestamps, but is still a short synthetic test, not a game benchmark.
Add `NIGHTFALL_XR_HEADSET_OPTICS=1` to a tracked-scene invocation to request
the headset's actual eye-relative poses/FOV before initializing the host HMD.
This requires the updated DEV APK; an older client fails explicitly instead
of silently retaining simulated optics. The no-headset fixture supplies known
synthetic optics and verifies their propagation. See
[headset optics](docs/research/meteor-xr-headset-optics.md) for limits and tests.

### Retired ALVR research probe

The exclusive Meteor XR spike is separate from normal APK builds. To check
the local toolchain or build the pinned Android ALVR client core:

```bash
bash tools/build_support/probe_alvr_client.sh --check
bash tools/build_support/probe_alvr_client.sh --build
```

`--build` downloads pinned source/submodules and local build tools into ignored
`.build-cache/meteor-xr/`, builds optimized arm64 code, generates the C header,
checks its C++ ABI and exported symbols, and records artifact hashes. It does
not install/register a SteamVR driver, change the active XR runtime, start
SteamVR, add PCVR discovery, or bundle the library into the APK. See the
[XR plan](docs/plans/active/meteor-xr-streaming-spike.md) and
[integration audit](docs/research/meteor-xr-alvr-integration.md) before attempting
the rendering bridge.

Optimized `--dev` APKs also expose **XR Projection Test** on the welcome screen.
Start from a clean welcome screen with no browser screens or desktop connection.
This synthetic test submits a tracked stereo floor and spheres through Godot's
existing OpenXR session; it does not connect to Meteor or stream PC video.
Hold B or Y for one second to exit, or wait for the 45-second automatic exit.
Putting the headset into standby also requests an exit. Normal content remains
hidden until the native projection has drained. This is a rendering bridge
experiment, not validation of the final network/decoder timing path.

The old ALVR adapter/build switch remains research material. Its remote entry
has been removed and rejects legacy requests. Ordinary builds do not package or
initialize it. The temporary host driver/wrapper was retired; see its integration
audit for backups and restoration evidence. Do not use it as the new spike path.

## 3. Deploy to Quest

```bash
adb install -r Nightfall-Android-arm64-v8a-debug.apk
```

## Project Structure

```
├── main.gd                  # Application root and top-level lifecycle
├── main.tscn                # Main Godot scene
├── build.sh                 # Android/Linux build, package, and install entry point
├── project.godot            # Godot project configuration
├── export_presets.cfg       # Android and Linux export presets
├── src/
│   ├── *_manager.gd          # Stream, screen, state, background, and XR managers
│   ├── *_controller.gd       # Settings and UI behavior
│   ├── native_xr_renderer.gd # GDScript bridge to the native renderer
│   ├── vr_screen.gd/.tscn    # Per-monitor screen implementation
│   ├── shaders/              # Mesh/composition/depth shader variants and includes
│   └── assets/               # UI, background, and branding assets
├── addons/
│   ├── nightfall-stream/     # Streaming/decode GDExtension source
│   └── godotopenxrvendors/   # Installed Meta OpenXR vendor plugin (gitignored)
├── extensions/nightfall-xr/       # Native Android OpenXR renderer source
├── android/
│   ├── src/main/java/         # Godot Android entry point and depth inference
│   ├── libs/                  # Patched LiteRT GPU AAR
│   └── patches/               # LiteRT patch provenance
├── meteor/                        # Nightfall Meteor, the PC companion (Rust; see meteor/README.md)
├── licences/                      # Third-party licence texts shown in Settings > Licences
├── locale/                        # UI translations (one JSON dictionary per language)
├── models/                        # Local depth models (weights are gitignored)
├── tools/                         # Model conversion and comparison tools
├── test/                          # GDScript and native tests/harnesses
├── docs/                          # Architecture, guides, plans, research, and archive
├── patches/                       # Godot engine patches
├── BUILD.md
└── README.md
```

## Export Presets

| Preset | Package | OpenGL Debug | Compress libs | Show in Launcher |
|---|---|---|---|---|
| `NightfallDev` | `app.nightfall.quest.debug` | yes | no | no |
| `NightfallRelease` | `app.nightfall.quest` | no | yes | yes |
| `NightfallLinux` | N/A (Linux Desktop) | N/A | N/A | N/A |

Both Android presets can coexist on the same device since they use different package names. The Linux preset targets Godot 4.7's `Linux` exporter and excludes the Android-only native-XR extension.

## Tests

Run the pure GDScript layout and preset tests with:

```bash
test/check_gdscript_parse.sh
test/run_gdscript_tests.sh
test/run_native_unit_tests.sh
tools/quality/check_shell_scripts.sh
python3 tools/quality/check_markdown_links.py
python3 tools/quality/check_generated_files.py
```

The runner isolates `user://` data under `/tmp`, supplies a writable log path,
and treats GDScript assertion messages as failures even when Godot exits with
status zero. Set `NIGHTFALL_GODOT_EDITOR` if Godot 4.7 is installed elsewhere.

Native desktop tests are built through CMake/CTest in
`addons/nightfall-stream` when `BUILD_TESTING` is enabled. The lightweight
native runner above builds the decode-queue unit test directly against the
installed FFmpeg development libraries. GitHub Actions runs these checks on
pull requests and pushes to `main`; the patched-engine and complete APK builds
remain explicit release checks because they are too large for every change.

## Key Architecture Notes

- **GDExtension Source**: `addons/nightfall-stream/src/`
- **V1 Reference**: The original Moonlight-Godot implementation was used as reference during development. Persistent source at `~/Development/Personal/moonlight-godot-src/`. Last commit with V1 code: `622e13a`.
- **vcpkg**: Persistent copy at `~/Development/Personal/vcpkg/`
- **JNI Handshake**: `GodotApp.java` loads the GDExtension library in a static block and calls `initializeMoonlightJNI()` to pass the JavaVM to FFmpeg for MediaCodec. This must happen before Godot initializes.
- **Android App Context**: `setAndroidContext()` passes the Android app context to FFmpeg via `av_jni_set_android_app_ctx()` with a JNI global reference.
- **MediaCodec**: Uses NDK `AMediaCodec` API (not Java JNI wrapper) via `ndk_codec=1` FFmpeg option.
- **AI 3D Async Pipeline**: `submit_depth_frame()` submits frames to a Java ExecutorService (non-blocking). `get_depth_map()` returns the latest cached result instantly via `AtomicReference`. Main thread never blocks on inference.
- **Build Cleanup**: `build.sh` removes `android/build/` after export to prevent Godot from scanning stale `.gdc`/`.gdextension` artifacts which cause duplicate class registration errors.
- **Full Rebuild Required**: All `.cpp` files must be recompiled together when `stream_core.h` changes. Partial rebuilds cause class layout mismatches (ODR violation) leading to SIGSEGV in audio init.
- **Module Architecture**: `main.gd` is the application root and currently owns
  shared state used by `src/` modules. Reducing that coupling is tracked in
  `docs/plans/active/repository-cleanup.md`.
