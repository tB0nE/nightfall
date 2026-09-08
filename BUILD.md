# Building Nightfall

## Prerequisites

- **Godot 4.7 stable** (editor + custom export templates)
- **Android NDK 29.0.14206865**
- **JDK 17**
- **vcpkg** (for GDExtension dependency management)
- **Ninja** (build system, used by CMake)
- **ADB** (for Quest deployment)

## 0. Install Godot Plugins

Open the project in the Godot editor and install the **GodotOpenXRVendors** plugin from the Asset Library (or enable it in Project → Install Plugins). This provides Meta Quest OpenXR vendor extensions.

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
export ANDROID_NDK_HOME=/path/to/ndk/27.0.12077973
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

Either way, the output is `bin/linux/libnightfall-stream.linux.template_release.x86_64.so`. AI 3D depth estimation works natively on Linux with the same selectable models as Android: MiDaS-192/256, YOLO26-N-256/320/384, and Depth Anything V2-196/252. No vcpkg `tensorflow-lite` port exists, so `CMakeLists.txt` vendors TFLite's own standalone CMake build directly via `FetchContent` (pinned to `v2.17.0`, matching the Android build's Gradle dependency) - this needs network access at CMake-configure time (not just `docker build` time) and is what makes the first build slower. The `.tflite` models ship as loose files next to the binary (`depth_models/`, populated by `build.sh` from `models/` - see `models/README.md`) rather than through Godot's PCK, since the Linux PCK export (below) never includes `models/`.

### Native OpenXR renderer (Quest/GLES)

Nightfall's fast presentation path is a separate GDExtension in
`extensions/nightfall-xr`. It samples MediaCodec's external OES texture
directly, renders both eyes into one double-wide OpenXR swapchain, and submits
two eye-specific sub-images through Godot's existing OpenXR frame loop. The
legacy Godot composition-layer path remains the automatic fallback for Linux,
multi-monitor layouts, diagnostic depth views, unsupported renderers, and
startup failures.

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

# Release build (requires .env with keystore credentials)
./build.sh --release

# Build and install via ADB
./build.sh --debug --install
./build.sh --release --install

# Linux AppImage
./build.sh --appimage
```

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
2. Exports PCK via Godot headless (using Android preset workaround)
3. Assembles Linux binary from release template + PCK
4. Creates AppDir with binary, PCK, .so files, plugin.gdextension, desktop entry, and icon
5. Builds AppImage via `appimagetool` (auto-downloaded to `/tmp/`)

### Depth models

Android bundles only ZipDepth-384-GPU. Linux bundles its existing MiDaS-256,
MiDaS-192, and Depth Anything V2-252 models. The `.tflite` files come from
`models/` and are not committed (`.gitignore`'s `/models/*.tflite`), so the
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
```

This downloads the Depth Anything V2 Small weights from HuggingFace, exports to
ONNX (196/252px input for the ViT-S patch-14 constraint), and converts to int8
quantized TFLite via `onnx2tf -kt input`. Output goes to `models/`.
ZipDepth's Adreno-safe graph rewrites and validation procedure are documented
in [`docs/guides/zipdepth-quest-gpu.md`](docs/guides/zipdepth-quest-gpu.md).

### Nightfall LiteRT GPU AAR

Normal Android builds use the checked-in `android/libs/litert-gpu-nightfall-1.4.2.aar`, a LiteRT 1.4.2 GPU delegate patched to select either a low-priority Qualcomm OpenCL context (`Stream`, the default) or the driver's normal context (`Default`) at runtime. Changing the AI 3D tab's GPU Priority setting recreates only the GPU delegate/interpreter; it does not restart the stream or app. With the native double-wide renderer, Stream priority protects the 90 Hz render cadence while MiDaS-256 inference remains around 30-35 ms.

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

Both Android presets can coexist on the same device since they use different package names. The Linux preset is not usable directly (Godot headless doesn't register LinuxBSD export platform); `build.sh --appimage` works around this via PCK export.

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
