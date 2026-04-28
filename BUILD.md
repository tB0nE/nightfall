# Building Nightfall

## Prerequisites

- **Godot 4.6.2** (editor + export templates)
- **Android NDK 27.0.12077973**
- **JDK 17**
- **vcpkg** (for dependency management)
- **Clang** (NDK-provided for Android, system for Linux)
- **ADB** (for Quest deployment)

## 0. Install Godot Plugins

Open the project in the Godot editor and install the **GodotOpenXRVendors** plugin from the Asset Library (or enable it in Project → Install Plugins). This provides Meta Quest OpenXR vendor extensions.

## 1. Clone and Build the GDExtension

The Moonlight GDExtension must be built from source. We maintain a fork with Quest hardware decoding patches:

```bash
# Clone our fork (quest-hw-decode branch has all patches applied)
git clone -b quest-hw-decode https://github.com/tB0nE/Moonlight-Godot.git /tmp/moonlight-godot-src
cd /tmp/moonlight-godot-src
```

The `quest-hw-decode` branch includes:
- JNI handshake for passing JavaVM/Android context to FFmpeg
- `ndk_codec=1` option forcing NDK MediaCodec path (HEVC hardware decode)
- Skip incompatible low-delay flags for MediaCodec
- Stats API (decoder name, frame counts, HW/SW status)

### Android (Quest) Build

```bash
NDK=/path/to/ndk/27.0.12077973
TOOLCHAIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64
CXX=$TOOLCHAIN/bin/aarch64-linux-android21-clang++
STRIP=$TOOLCHAIN/bin/llvm-strip
VCPKG=/tmp/moonlight-godot-src/build/android/vcpkg_installed/arm64-android
SRC=/tmp/moonlight-godot-src/src
BUILDDIR=/tmp/moonlight-godot-src/build/android

INCLUDES="-I$VCPKG/include -I$BUILDDIR/vcpkg_installed/x64-linux/include -I$SRC \
  -I$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include \
  -I$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/include/aarch64-linux-android"

mkdir -p /tmp/moonlight-godot-src/obj

# Compile all source files
for f in moonlight_godot register_types doc_classes stream_core_main stream_core_video \
         stream_core_audio stream_core_input stream_core_input_enum stream_core_struct \
         stream_core_utils moonlight_computer_manager moonlight_requester moonlight_config_manager; do
  $CXX $FLAGS $INCLUDES -c $SRC/$f.cpp -o /tmp/moonlight-godot-src/obj/$f.o
done

# Link
$CXX -shared -o /tmp/moonlight-godot-src/obj/libmoonlight-godot.android.arm64.so \
  /tmp/moonlight-godot-src/obj/*.o \
  -L$VCPKG/lib \
  -lavcodec -lavformat -lavutil -lswresample -lswscale -lavfilter \
  -lopus -lmoonlight-common-c -lenet -lcurl -lssl -lcrypto -lnghttp2 -lz \
  -lbrotlicommon -lbrotlidec -lbrotlienc -ldav1d -laom \
  -lgodot-cpp.android.arm64-v8a.template_release.arm64 \
  -llog -landroid -lmediandk
```

#### Debug Build

```bash
FLAGS="-fPIC -std=c++17 -DANDROID_ENABLED -D__ANDROID__ -g -O2"
# (compile + link with above flags, then install unstripped)
cp /tmp/moonlight-godot-src/obj/libmoonlight-godot.android.arm64.so \
  <project-root>/addons/moonlight-godot/bin/android/libmoonlight-godot.android.template_debug.arm64.so
```

#### Release Build

```bash
FLAGS="-fPIC -std=c++17 -DANDROID_ENABLED -D__ANDROID__ -O2"
# (compile + link with above flags, then strip debug symbols)
$STRIP --strip-debug /tmp/moonlight-godot-src/obj/libmoonlight-godot.android.arm64.so \
  -o <project-root>/addons/moonlight-godot/bin/android/libmoonlight-godot.android.template_release.arm64.so
```

> **Size comparison**: Debug ~165MB, Release (stripped) ~35MB.

### Linux (Desktop) Build

```bash
cd /tmp/moonlight-godot-src
mkdir -p build/linux && cd build/linux
cmake ../.. -DCMAKE_BUILD_TYPE=Debug -DVCPKG_TARGET_TRIPLET=x64-linux
cmake --build . --config Debug
cp libmoonlight-godot.*.so <project-root>/addons/moonlight-godot/bin/linux/
```

## 2. Export the APK

```bash
# Clean the android build directory
rm -rf <project-root>/android/build
mkdir -p <project-root>/android/build
cd <project-root>/android/build

# Extract Godot Android export template
unzip -q "/path/to/Godot/editor_data/export_templates/4.6.2.stable/android_source.zip"

# Copy custom Java file
cp ../src/main/java/com/godot/game/GodotApp.java src/main/java/com/godot/game/GodotApp.java

# Debug export
JAVA_HOME=/path/to/jdk17 /path/to/godot --headless --path <project-root> \
  --export-debug "NightfallDev" <project-root>/Nightfall-Android-arm64-v8a-debug.apk

# Release export
JAVA_HOME=/path/to/jdk17 /path/to/godot --headless --path <project-root> \
  --export-release "NightfallRelease" <project-root>/Nightfall-Android-arm64-v8a.apk
```

## 3. Deploy to Quest

```bash
adb install -r Nightfall-Android-arm64-v8a-debug.apk
```

## Project Structure

```
├── main.gd              # Coordinator: state, _ready, _process, _input, XR setup
├── main.tscn            # Scene tree
├── project.godot        # Godot project config
├── export_presets.cfg   # Debug + Release Android export presets
├── src/
│   ├── stream_manager.gd     # Pairing, streaming lifecycle, audio, texture binding, stats
│   ├── xr_interaction.gd     # Raycasts, grab bars, UI clicks, env movement
│   ├── input_handler.gd      # Keyboard/mouse/controller forwarding, stream mouse capture
│   ├── ui_controller.gd      # Numpad, SBS toggle, mode switching, stereo shader
│   ├── auto_detect.gd        # SBS auto-detection logic
│   ├── stereo_screen.gdshader  # YUV→RGB + SBS stereo shader
│   ├── openxr_action_map.tres  # OpenXR controller bindings
│   └── icon.svg               # App icon
├── addons/
│   └── moonlight-godot/  # GDExtension (built from fork)
├── android/
│   └── src/main/java/    # GodotApp.java (JNI handshake)
├── BUILD.md
└── README.md
```

## Export Presets

| Preset | Package | OpenGL Debug | Compress libs | Show in Launcher |
|---|---|---|---|---|
| `NightfallDev` | `app.nightfall.quest.debug` | yes | no | no |
| `NightfallRelease` | `app.nightfall.quest` | no | yes | yes |

Both presets can coexist on the same device since they use different package names.

## Key Architecture Notes

- **Fork**: `https://github.com/tB0nE/Moonlight-Godot` (branch: `quest-hw-decode`) — upstream is `html5syt/Moonlight-Godot`
- **JNI Handshake**: `GodotApp.java` loads the GDExtension library in a static block and calls `initializeMoonlightJNI()` to pass the JavaVM to FFmpeg for MediaCodec. This must happen before Godot initializes.
- **Android App Context**: `setAndroidContext()` passes the Android app context to FFmpeg via `av_jni_set_android_app_ctx()` with a JNI global reference.
- **MediaCodec**: Uses NDK `AMediaCodec` API (not Java JNI wrapper) via `ndk_codec=1` FFmpeg option.
- **Full Rebuild Required**: All `.cpp` files must be recompiled together when `stream_core.h` changes. Partial rebuilds cause class layout mismatches (ODR violation) leading to SIGSEGV in audio init.
- **Module Architecture**: `main.gd` is a thin coordinator holding shared state. Logic is split into `src/` modules (RefCounted classes) that receive a reference to the main node.
