# Building Nightfall

## Prerequisites

- **Godot 4.7 Beta 2** (editor + export templates)
- **Android NDK 27.0.12077973**
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

Either way, the output is `bin/linux/libnightfall-stream.linux.template_release.x86_64.so`. AI 3D depth estimation works natively on Linux (2026-08-20) - MiDaS-192/256 only for now (no vendor NNAPI HAL on Quest either, so CPU-only isn't a capability downgrade vs Android; YOLO26/DA V2 aren't ported yet). No vcpkg `tensorflow-lite` port exists, so `CMakeLists.txt` vendors TFLite's own standalone CMake build directly via `FetchContent` (pinned to `v2.16.1`, matching the Android build's Gradle dependency) - this needs network access at CMake-configure time (not just `docker build` time) and is what makes the first build slower. The two MiDaS `.tflite` models ship as loose files next to the binary (`depth_models/`, populated by `build.sh`) rather than through Godot's PCK, since the Linux PCK export (below) never includes `android/src/main/assets/`.

### Patched Godot Engine (Quest only)

The Quest's zero-copy GPU decode pipeline requires a custom Godot engine build with Vulkan Android Hardware Buffer (AHB) import support. The patch adds two RenderingDevice methods: `texture_create_from_android_hardware_buffer` and `texture_get_ycbcr_sampler`.

**You must build BOTH debug and release templates** and place them in the export templates directory. Without the release template, the release APK will silently fall back to the unpatched engine and show a black screen.

```bash
# Clone Godot 4.7 and apply the patch
git clone -b 4.7 https://github.com/godotengine/godot.git /tmp/godot
cd /tmp/godot
git apply /path/to/moonlight-quest/patches/godot-4.7-ahb.patch

# Build debug template
scons platform=android target=template_debug arch=arm64 -j$(nproc)
cp bin/libgodot.android.template_debug.arm64.so \
   ~/.local/share/godot/export_templates/4.7.stable/android_debug_arm64.so

# Build release template
scons platform=android target=template_release arch=arm64 -j$(nproc)
cp platform/android/java/lib/libs/release/arm64-v8a/libgodot_android.so \
   ~/.local/share/godot/export_templates/4.7.stable/android_release_arm64.so
```

> **Note**: The release template output is moved by scons to `platform/android/java/lib/libs/release/arm64-v8a/` — copy it from there, not from `bin/`.

> **Note**: `build.sh` also copies the patched `.so` (from `addons/nightfall-stream/bin/android/libgodot_android.so`) into the extracted Gradle project during export as a safety net. Keep this file in sync with the template.

The required Android SDK/NDK paths are auto-detected if `ANDROID_HOME` is configured in the Godot editor settings (stored in `~/.config/godot/editor_settings-4.7.tres`).

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
1. Wipes `android/build/` and extracts Godot Android template
2. Copies `GodotApp.java` and `DepthEstimator.java`
3. Copies TFLite models to assets (MiDaS + Depth Anything V2 if present)
4. Patches `build.gradle` with `tensorflow-lite:2.16.1` dependency
5. Copies Meta OpenXR vendor plugin AAR
6. Exports APK via Godot headless
7. Cleans up `android/build/` (prevents Godot editor duplicate class errors)
8. Optionally installs via ADB

For Linux AppImage (`--appimage`):
1. Builds Linux .so in Ubuntu 22.04 Docker container (glibc 2.35 compat, skips if .so already exists)
2. Exports PCK via Godot headless (using Android preset workaround)
2. Assembles Linux binary from release template + PCK
3. Creates AppDir with binary, PCK, .so files, plugin.gdextension, desktop entry, and icon
4. Builds AppImage via `appimagetool` (auto-downloaded to `/tmp/`)

### Generate Depth Anything V2 Model

The MiDaS model (`midas-midas-v2-w8a8.tflite`, 17MB) is included in the repo. The Depth Anything V2 model (`depth-anything-v2-small.tflite`, 85MB) must be generated separately:

```bash
# Requires: Python 3.12+ with PyTorch, onnx2tf, onnxsim
pip install onnx2tf sng4onnx onnxsim

python3 tools/convert_depth_anything_v2.py
```

This downloads the Depth Anything V2 Small weights from HuggingFace, exports to ONNX (252x252 input for DINOv2 patch size), and converts to int8 quantized TFLite. The output is placed at `android/src/main/assets/depth-anything-v2-small.tflite`.

The app works without it - AI 3D mode will use MiDaS only. AI 3D v2 mode will fall back to MiDaS if the model file is missing.

## 3. Deploy to Quest

```bash
adb install -r Nightfall-Android-arm64-v8a-debug.apk
```

## Project Structure

```
├── main.gd              # Coordinator: state, _ready, _process, _input, XR setup
├── main.tscn            # Scene tree
├── build.sh             # Build script (export + install)
├── project.godot        # Godot project config
├── export_presets.cfg   # Debug + Release Android export presets
├── src/
│   ├── shaders/
│   │   ├── stereo_screen.gdshader    # 2D + SBS Stretch + SBS Crop + AI 3D DIBR shader
│   │   ├── star.gdshader             # Star particle shader (color tints + flicker)
│   │   ├── keyboard_screen.gdshader  # DEPRECATED (broken with ViewportTexture)
│   │   └── composite_screen.gdshader # DEPRECATED (composite mode removed)
│   ├── stream_manager.gd     # Pairing, streaming lifecycle, audio, texture binding, stats
│   ├── xr_interaction.gd     # Raycasts, grab bars, corner resize, UI clicks
│   ├── input_handler.gd      # Keyboard/mouse/controller forwarding, stream mouse capture
│   ├── ui_controller.gd      # Numpad, mode toggle, stereo shader, UI updates
│   ├── auto_detect.gd        # SBS auto-detection logic
│   ├── depth_estimator.gd    # AI 3D: SubViewport capture, JNI depth pipeline, texture update
│   ├── virtual_keyboard.gd   # Full QWERTY keyboard overlay
│   ├── openxr_action_map.tres  # OpenXR controller bindings
│   └── assets/               # nightfall_icon_v1.png, pc_icon.svg, backgrounds
├── addons/
│   ├── nightfall-stream/      # GDExtension (built from source)
│   └── godotopenxrvendors/    # Meta OpenXR vendor plugin v5.0.0
├── android/
│   └── src/main/
│       ├── java/com/godot/game/  # GodotApp.java, DepthEstimator.java
│       └── assets/               # midas-midas-v2-w8a8.tflite (depth-anything-v2-small.tflite generated separately)
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
- **Module Architecture**: `main.gd` is a thin coordinator holding shared state. Logic is split into `src/` modules (RefCounted classes) that receive a reference to the main node.
