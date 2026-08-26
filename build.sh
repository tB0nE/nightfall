#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PRESET="NightfallDev"
OUTPUT="Nightfall-Android-arm64-v8a-debug.apk"
PLATFORM="android"

for arg in "$@"; do
  case "$arg" in
    --release) PRESET="NightfallRelease"; OUTPUT="Nightfall-Android-arm64-v8a.apk" ;;
    --debug)   PRESET="NightfallDev";     OUTPUT="Nightfall-Android-arm64-v8a-debug.apk" ;;
    --linux)   PLATFORM="linux"; OUTPUT="Nightfall-Linux-x86_64" ;;
    --appimage) PLATFORM="appimage"; OUTPUT="Nightfall-x86_64.AppImage" ;;
    --install) INSTALL=1 ;;
    --help|-h)
      echo "Usage: $0 [--debug|--release] [--linux|--appimage] [--install]"
      echo "  --debug     Export debug APK (default)"
      echo "  --release   Export release APK (requires .env keystore config)"
      echo "  --linux     Export Linux x86_64 binary"
      echo "  --appimage  Export Linux x86_64 AppImage (implies --release for Linux)"
      echo "  --install   Install APK via adb after export (Android only)"
      exit 0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

GODOT="/var/home/tyrone/Applications/Godot_v4.7-stable_linux.x86_64"
JAVA_HOME="/home/linuxbrew/.linuxbrew/opt/openjdk@17"
TEMPLATES="/var/home/tyrone/.local/share/godot/export_templates/4.7.stable/android_source.zip"
LINUX_TEMPLATE_DEBUG="/var/home/tyrone/.local/share/godot/export_templates/4.7.stable/linux_debug.x86_64"
LINUX_TEMPLATE_RELEASE="/var/home/tyrone/.local/share/godot/export_templates/4.7.stable/linux_release.x86_64"

CONFIG="export_presets.cfg"
CONFIG_BACKUP="export_presets.cfg.bak"

if [ "$PLATFORM" = "linux" ] || [ "$PLATFORM" = "appimage" ]; then
  LINUX_TEMPLATE="$LINUX_TEMPLATE_RELEASE"
  LINUX_SO="$SCRIPT_DIR/addons/nightfall-stream/bin/linux/libnightfall-stream.linux.template_release.x86_64.so"

  if [ ! -f "$LINUX_TEMPLATE" ]; then
    echo "Error: Linux template not found at $LINUX_TEMPLATE"
    exit 1
  fi

  echo "Building Linux .so in Ubuntu 22.04 Docker container (glibc 2.35 compat)..."
  bash "$SCRIPT_DIR/docker-build-linux.sh"

  if [ ! -f "$LINUX_SO" ]; then
    echo "Error: Linux .so build failed"
    exit 1
  fi

  LINUX_BINARY="$SCRIPT_DIR/Nightfall-Linux-x86_64"
  PCK_PATH="$SCRIPT_DIR/Nightfall-Linux.pck"
  APPDIR="$SCRIPT_DIR/Nightfall.AppDir"
  rm -f "$PCK_PATH" "$LINUX_BINARY"
  rm -rf "$APPDIR"

  echo "Exporting PCK for Linux (using Android preset for headless compatibility)..."
  "$GODOT" --headless --path "$SCRIPT_DIR" --export-pack NightfallDev "$PCK_PATH" 2>&1

  if [ ! -f "$PCK_PATH" ]; then
    echo "Error: PCK export failed"
    exit 1
  fi

  echo "Assembling Linux binary from template + PCK..."
  cp "$LINUX_TEMPLATE" "$LINUX_BINARY"
  cat "$PCK_PATH" >> "$LINUX_BINARY"
  chmod +x "$LINUX_BINARY"

  SIZE=$(ls -lh "$LINUX_BINARY" | awk '{print $5}')
  echo "Assembled Linux binary ($SIZE)"

  # Native AI-3D depth on Linux (MiDaS only, 2026-08-20) - midas_depth_engine.cpp
  # resolves its model directory relative to the running executable's own path
  # (OS::get_executable_path()'s base dir + "/depth_models"), NOT through
  # Godot's res:///PCK - the PCK export above uses the Android preset as a
  # headless-export workaround and never includes models/ or android/src/main/assets/.
  # Same "loose files next to the binary" pattern as the .so/AAR copies below.
  # Models live in models/ (gitignored, not committed - see models/README.md
  # for the full manifest and how to obtain each file) rather than
  # android/src/main/assets/ (2026-08-24) - both Android and Linux now pull
  # from the same single source directory instead of Android's assets folder
  # doing double duty as the canonical location for a non-Android platform.
  mkdir -p "$SCRIPT_DIR/depth_models"
  cp "$SCRIPT_DIR/models/midas-midas-v2-w8a8.tflite" "$SCRIPT_DIR/depth_models/"
  cp "$SCRIPT_DIR/models/midas-v21-small-192-int8.tflite" "$SCRIPT_DIR/depth_models/"
  cp "$SCRIPT_DIR/models/depth-anything-v2-small-252.tflite" "$SCRIPT_DIR/depth_models/"

  rm -f "$SCRIPT_DIR/openxr_action_map.tres"

  if [ "$PLATFORM" = "appimage" ]; then
    APPDIR="$SCRIPT_DIR/Nightfall.AppDir"
    rm -rf "$APPDIR"
    mkdir -p "$APPDIR/usr/bin"
    mkdir -p "$APPDIR/usr/share/applications"
    mkdir -p "$APPDIR/usr/share/icons/hicolor/732x732/apps"

    cp "$LINUX_TEMPLATE" "$APPDIR/usr/bin/nightfall-quest"
    cp "$PCK_PATH" "$APPDIR/usr/bin/nightfall-quest.pck"
    chmod +x "$APPDIR/usr/bin/nightfall-quest"

    mkdir -p "$APPDIR/usr/bin/addons/nightfall-stream/bin/linux"
    mkdir -p "$APPDIR/usr/bin/addons/godotopenxrvendors/.bin/linux/template_release/x86_64"
    mkdir -p "$APPDIR/usr/bin/depth_models"
    cp "$SCRIPT_DIR/addons/nightfall-stream/bin/linux/libnightfall-stream.linux.template_release.x86_64.so" "$APPDIR/usr/bin/addons/nightfall-stream/bin/linux/"
    cp "$SCRIPT_DIR/addons/godotopenxrvendors/.bin/linux/template_release/x86_64/libgodotopenxrvendors.so" "$APPDIR/usr/bin/addons/godotopenxrvendors/.bin/linux/template_release/x86_64/"
    cp "$SCRIPT_DIR/depth_models/"*.tflite "$APPDIR/usr/bin/depth_models/"
    cp "$SCRIPT_DIR/addons/godotopenxrvendors/plugin.gdextension" "$APPDIR/usr/bin/addons/godotopenxrvendors/"
    cp "$SCRIPT_DIR/nightfall-quest.desktop" "$APPDIR/nightfall-quest.desktop"
    cp "$SCRIPT_DIR/nightfall-quest.desktop" "$APPDIR/usr/share/applications/nightfall-quest.desktop"
    cp "$SCRIPT_DIR/src/assets/nightfall_icon_v1.png" "$APPDIR/usr/share/icons/hicolor/732x732/apps/nightfall-quest.png"
    cp "$SCRIPT_DIR/src/assets/nightfall_icon_v1.png" "$APPDIR/nightfall-quest.png"

    cat > "$APPDIR/AppRun" << 'APPRUN'
#!/usr/bin/env bash
APPDIR="$(dirname "$(readlink -f "$0")")"
export APPDIR
cd "$APPDIR/usr/bin"
exec ./nightfall-quest "$@"
APPRUN
    chmod +x "$APPDIR/AppRun"

    echo "Building AppImage..."
    APPIMAGETOOL="/tmp/appimagetool"
    if [ ! -f "$APPIMAGETOOL" ]; then
      echo "Downloading appimagetool..."
      curl -L -o "$APPIMAGETOOL" "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
      chmod +x "$APPIMAGETOOL"
    fi

    ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$SCRIPT_DIR/$OUTPUT" 2>&1

    if [ ! -f "$SCRIPT_DIR/$OUTPUT" ]; then
      echo "Error: AppImage creation failed"
      rm -rf "$APPDIR"
      exit 1
    fi

    chmod +x "$SCRIPT_DIR/$OUTPUT"
    SIZE=$(ls -lh "$SCRIPT_DIR/$OUTPUT" | awk '{print $5}')
    echo "Exported $OUTPUT ($SIZE)"

    rm -rf "$APPDIR"
    rm -f "$PCK_PATH"
  fi

  rm -f "$PCK_PATH"
  exit 0
fi

if [ "$PRESET" = "NightfallRelease" ]; then
  if [ ! -f .env ]; then
    echo "Error: .env not found (copy .env.example and fill in keystore credentials)"
    exit 1
  fi
  source .env
  if [ -z "${NIGHTFALL_KEYSTORE_PATH:-}" ] || [ -z "${NIGHTFALL_KEYSTORE_USER:-}" ] || [ -z "${NIGHTFALL_KEYSTORE_PASSWORD:-}" ]; then
    echo "Error: .env missing NIGHTFALL_KEYSTORE_PATH, NIGHTFALL_KEYSTORE_USER, or NIGHTFALL_KEYSTORE_PASSWORD"
    exit 1
  fi
  cp "$CONFIG" "$CONFIG_BACKUP"
  sed -i \
    -e "s|\${NIGHTFALL_KEYSTORE_PATH}|${NIGHTFALL_KEYSTORE_PATH}|g" \
    -e "s|\${NIGHTFALL_KEYSTORE_USER}|${NIGHTFALL_KEYSTORE_USER}|g" \
    -e "s|\${NIGHTFALL_KEYSTORE_PASSWORD}|${NIGHTFALL_KEYSTORE_PASSWORD}|g" \
    "$CONFIG"
  echo "Patched keystore credentials into $CONFIG"
fi

cleanup() {
  if [ -f "$CONFIG_BACKUP" ]; then
    mv "$CONFIG_BACKUP" "$CONFIG"
    echo "Restored original $CONFIG"
  fi
}
trap cleanup EXIT

rm -rf android/build
mkdir -p android/build
cd android/build
unzip -q "$TEMPLATES"
sed -i '/tools:targetApi="29" \/>/a\
\
        <meta-data\
            android:name="com.oculus.trade_cpu_for_gpu_amount"\
            android:value="1" />' src/main/AndroidManifest.xml
# Replace Godot .so with patched version (AHB Vulkan patch for Quest)
# Cover all locations the Gradle build might pick up the .so from
cp "$SCRIPT_DIR/addons/nightfall-stream/bin/android/libgodot_android.so" aar_extract/jni/arm64-v8a/libgodot_android.so 2>/dev/null || true
mkdir -p libs/release/arm64-v8a libs/debug/arm64-v8a
cp "$SCRIPT_DIR/addons/nightfall-stream/bin/android/libgodot_android.so" libs/release/arm64-v8a/libgodot_android.so 2>/dev/null || true
cp "$SCRIPT_DIR/addons/nightfall-stream/bin/android/libgodot_android.so" libs/debug/arm64-v8a/libgodot_android.so 2>/dev/null || true
cd "$SCRIPT_DIR"
cp android/src/main/java/com/godot/game/GodotApp.java android/build/src/main/java/com/godot/game/GodotApp.java
cp android/src/main/java/com/godot/game/DepthEstimator.java android/build/src/main/java/com/godot/game/DepthEstimator.java
# Godot's own Android export always wipes and repopulates src/main/assets from
# scratch right before invoking gradle (EditorExportPlatformAndroid::_clear_assets_directory(),
# platform/android/export/export_plugin.cpp) - it's the directory Godot writes its own
# project pck data into, so anything staged there before export() runs is deleted
# regardless of ordering. Gradle's own asset merge (mergeDebugAssets/mergeReleaseAssets)
# supports multiple source directories per source set though, so a sibling directory
# declared via sourceSets below survives untouched and still gets merged into the APK.
# Models live in models/ (gitignored, not committed - see models/README.md
# for the full manifest and how to obtain each file), not
# android/src/main/assets/ (2026-08-24) - see the matching comment in the
# Linux depth_models block above.
mkdir -p android/build/nightfallAssets
cp "$SCRIPT_DIR/models/midas-midas-v2-w8a8.tflite" android/build/nightfallAssets/
cp "$SCRIPT_DIR/models/midas-v21-small-256-gpu.tflite" android/build/nightfallAssets/
# MiDaS-small re-exported/re-calibrated at 192x192 (2026-08-20) - an
# independently-calibrated sibling of the 256px model above, not just a
# resize (own scale/zero_point, see DepthEstimator.java's MIDAS_192_*
# constants). Now the default landing spot right after Off (see
# settings_controller.gd's ai_3d_model_labels comment).
cp "$SCRIPT_DIR/models/midas-v21-small-192-int8.tflite" android/build/nightfallAssets/
# MiDaS-192-GPU (2026-08-24) - same onnx2tf -ofgd -kt input recipe that
# produced the working 256px GPU export (see midas-v21-small-256-gpu.tflite's
# own history), just re-run against the ONNX graph's input resized to
# 192x192 - MiDaS-small's Resize ops use relative scale factors, not
# hardcoded absolute sizes, so it's resolution-agnostic. Verified clean
# 73 CONV_2D/24 DEPTHWISE_CONV_2D/5 RESIZE_BILINEAR graph (matches the
# 256px model's op composition exactly) and non-degenerate real inference
# output before bundling. This is the float32-I/O sibling of that export
# (NOT onnx2tf's literal-fp16-tensor output) - confirmed on-device the
# fp16-I/O version fails identically to the 256px model's own documented
# history ("(CONV_2D) failed to prepare, Node number 3"); the GPU delegate
# still runs at fp16 precision internally via setPrecisionLossAllowed(true)
# in DepthEstimator.java, it just needs a float32 tensor boundary.
# Re-quantized (2026-08-25) - the first bundled version was a plain
# all-float32 export (64MB), nearly 2x the reference 256px model (33MB)
# despite the smaller input, because that 256px asset was never built by
# this project - it's an externally-sourced export that already used
# TFLite's standard weight-only float16 quantization internally (fp16
# CONV weights, float32 I/O boundary - the same technique
# setPrecisionLossAllowed(true) exploits at the delegate level). Applied
# the same technique here directly via tf.lite.TFLiteConverter
# (optimizations=[DEFAULT], target_spec.supported_types=[float16]) against
# the SavedModel onnx2tf's tf_converter backend produces - onnx2tf's own
# "_float16.tflite" sibling isn't this; it's a literal fp16 I/O boundary
# export that fails to load (same root cause as this comment's own
# fp16-I/O history above). Result: 33.2MB, verified same float32 I/O +
# fp16-weight tensor pattern as the reference model, non-degenerate output.
cp "$SCRIPT_DIR/models/midas-v21-small-192-gpu.tflite" android/build/nightfallAssets/
# YOLO26-depth (nano, all resolutions) and YOLO26-N-384-GPU REMOVED from
# selection (2026-08-25) - the w8a32 nano CPU lineup and a fresh
# NHWC/CNN-dominated GPU export were both tried, but the GPU delegate never
# loaded on-device ("Failed to apply delegates") and the CPU lineup wasn't
# worth keeping bundled without it. Same soft-fail pattern as YOLO26-S
# below: DepthEstimator.java still attempts to load these (harmless, no
# asset present) and the files stay in models/ untouched if revisited.
# Depth Anything V2 Small, REVIVED (2026-08-20) - the originally-deployed
# fp16 asset was fully dead code (never loaded on this CPU path at all: an
# "input_type == kTfLiteFloat32 ... was not true" failure on every attempt,
# same class of bug MiDaS-GPU's fp16 export originally hit), so this isn't
# "re-bundling a working but retired model" - it's a genuinely new
# capability. Re-converted via onnx2tf -kt input (fixes a layout-mangling
# bug that made every prior export produce spatially incoherent output)
# and shipped with dilate/blur post-processing OFF (was hardcoded on) -
# see DepthEstimator.java's MODEL_DA_196/252 comment for both fixes' full
# history. DA-V2-196 REMOVED from selection (2026-08-25, kept as loading
# code only, same soft-fail pattern as YOLO26-S) - both DA-V2 resolutions
# are impractically slow on real streaming content (CPU-only, no viable
# GPU path - see DA-V2-196-GPU's history below), so only one is kept
# bundled at all, as a curiosity/future-hardware placeholder rather than
# a genuinely usable option today. 252 kept over 196 as the higher-quality
# of the two.
cp "$SCRIPT_DIR/models/depth-anything-v2-small-252.tflite" android/build/nightfallAssets/
# DA-V2-196-GPU tried (2026-08-25), REMOVED from selection - the GPU
# delegate loaded and produced correct output (same onnx2tf -kt input fix
# as the CPU models above), but only at ~2.8Hz vs. MiDaS-GPU's ~15-20Hz -
# DA-V2's ViT backbone repeats an unsupported-op region 12 times, forcing
# 12 GPU<->CPU handoffs per inference that dominate the cost. See
# DepthEstimator.java's comment near the (removed) MODEL_DA_196_GPU
# constant for the full history if revisiting.
LITERT_GPU_AAR="$SCRIPT_DIR/android/libs/litert-gpu-nightfall-1.4.2.aar"
if [ ! -f "$LITERT_GPU_AAR" ]; then
  echo "Error: patched LiteRT GPU AAR not found at $LITERT_GPU_AAR"
  exit 1
fi
# The local GPU AAR is the official LiteRT 1.4.2 artifact with only its arm64
# JNI library replaced. Nightfall's JNI build adds Qualcomm's low-priority
# OpenCL context hint; keeping the Java API artifact separate avoids Gradle
# resolving the stock native library transitively alongside it.
sed -i '/implementation "androidx.documentfile:documentfile/a\\n    implementation "com.google.ai.edge.litert:litert:1.4.2"\n    implementation "com.google.ai.edge.litert:litert-gpu-api:1.4.2"\n    implementation files("../libs/litert-gpu-nightfall-1.4.2.aar")' android/build/build.gradle
sed -i "s|main.res.srcDirs += \['res'\]|main.res.srcDirs += ['res']\n        main.assets.srcDirs += ['nightfallAssets']|" android/build/build.gradle
# mmap'd via AssetManager.openFd() at runtime (DepthEstimator.java), which requires
# the entry be stored uncompressed in the APK
sed -i '/ignoreAssetsPattern/a\            noCompress "tflite"' android/build/build.gradle
if [ "$PRESET" = "NightfallDev" ]; then
  mkdir -p android/build/libs/debug
  cp "$SCRIPT_DIR/addons/godotopenxrvendors/.bin/android/debug/godotopenxr-meta-debug.aar" android/build/libs/debug/ 2>/dev/null || true
else
  mkdir -p android/build/libs/release
  cp "$SCRIPT_DIR/addons/godotopenxrvendors/.bin/android/release/godotopenxr-meta-release.aar" android/build/libs/release/ 2>/dev/null || true
fi

echo "Exporting $PRESET..."
EXPORT_FLAG="--export-debug"

if [ "$PRESET" = "NightfallRelease" ]; then
  EXPORT_FLAG="--export-release"
fi

JAVA_HOME="$JAVA_HOME" "$GODOT" --headless --path "$SCRIPT_DIR" $EXPORT_FLAG "$PRESET" "$SCRIPT_DIR/$OUTPUT" 2>&1

if [ ! -f "$OUTPUT" ]; then
  echo "Error: $OUTPUT not created"
  exit 1
fi

SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
echo "Exported $OUTPUT ($SIZE)"

rm -rf "$SCRIPT_DIR/android/build"
rm -f "$SCRIPT_DIR/openxr_action_map.tres"

if [ "${INSTALL:-0}" = "1" ]; then
  echo "Installing on device..."
  adb install -r "$OUTPUT"
  echo "Done!"
fi
