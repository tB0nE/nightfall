#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <Godot preset> <output filename>" >&2
  exit 1
fi

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$TOOL_DIR/../.." && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=native_xr_versions.sh
source "$TOOL_DIR/native_xr_versions.sh"

PRESET="$1"
OUTPUT="$2"
USE_STOCK_LITERT="${NIGHTFALL_USE_STOCK_LITERT:-0}"
INSTALL="${NIGHTFALL_INSTALL:-0}"
GODOT="${NIGHTFALL_GODOT_EDITOR:?Set NIGHTFALL_GODOT_EDITOR to a Godot 4.7 executable}"
JAVA_HOME="${NIGHTFALL_JAVA_HOME:-${JAVA_HOME:-/home/linuxbrew/.linuxbrew/opt/openjdk@17}}"
GODOT_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/godot"
GODOT_TEMPLATE_DIR="${NIGHTFALL_GODOT_TEMPLATE_DIR:-$GODOT_DATA_HOME/export_templates/$NIGHTFALL_GODOT_TEMPLATE_VERSION}"
TEMPLATES="${NIGHTFALL_ANDROID_SOURCE_TEMPLATE:-$GODOT_TEMPLATE_DIR/android_source.zip}"
CONFIG="export_presets.cfg"
CONFIG_BACKUP="export_presets.cfg.bak"

# The Godot export packages the prebuilt streaming GDExtension. Refuse to
# silently ship an older binary when its native sources changed; otherwise new
# methods can appear in GDScript while being absent from the installed .so.
STREAM_VARIANT="debug"
if [ "$PRESET" = "NightfallRelease" ]; then
  STREAM_VARIANT="release"
fi
STREAM_LIBRARY="$SCRIPT_DIR/addons/nightfall-stream/bin/android/libnightfall-stream.android.template_${STREAM_VARIANT}.arm64.so"
if [ ! -f "$STREAM_LIBRARY" ]; then
  echo "Error: Android streaming GDExtension not found at $STREAM_LIBRARY"
  echo "Build it first using the Android instructions in BUILD.md."
  exit 1
fi
STREAM_SOURCE_NEWER="$(find \
  "$SCRIPT_DIR/addons/nightfall-stream/src" \
  "$SCRIPT_DIR/addons/nightfall-stream/CMakeLists.txt" \
  -type f -newer "$STREAM_LIBRARY" -print -quit)"
if [ -n "$STREAM_SOURCE_NEWER" ]; then
  echo "Error: Android streaming GDExtension is stale (newer source: $STREAM_SOURCE_NEWER)"
  echo "Rebuild the $STREAM_VARIANT streaming GDExtension using BUILD.md, then retry."
  exit 1
fi

# Build the Android OpenXR composition provider before export. It is kept as
# a separate GDExtension because the generic vcpkg godot-cpp API omits the
# OpenXR module classes it derives from. Linux keeps using the legacy Godot
# composition-layer path and must not require the Android NDK.
NATIVE_XR_TARGET="debug"
if [ "$PRESET" = "NightfallRelease" ]; then
  NATIVE_XR_TARGET="release"
fi
bash "$SCRIPT_DIR/extensions/nightfall-xr/build_android.sh" "$NATIVE_XR_TARGET"

NATIVE_XR_CACHE="${NIGHTFALL_NATIVE_XR_CACHE:-$SCRIPT_DIR/.build-cache/native-xr}"
PATCHED_GODOT_RUNTIME="${NIGHTFALL_GODOT_ANDROID_RUNTIME:-$NATIVE_XR_CACHE/templates/$NIGHTFALL_GODOT_TEMPLATE_VERSION/android_${NATIVE_XR_TARGET}_arm64.so}"
if [ ! -f "$PATCHED_GODOT_RUNTIME" ]; then
  echo "Error: patched Godot Android runtime not found at $PATCHED_GODOT_RUNTIME"
  echo "Run tools/build_support/bootstrap_native_xr.sh first."
  exit 1
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
cp "$PATCHED_GODOT_RUNTIME" aar_extract/jni/arm64-v8a/libgodot_android.so
mkdir -p libs/release/arm64-v8a libs/debug/arm64-v8a
cp "$PATCHED_GODOT_RUNTIME" "libs/$NATIVE_XR_TARGET/arm64-v8a/libgodot_android.so"
cd "$SCRIPT_DIR"
cp android/src/main/java/com/godot/game/GodotApp.java android/build/src/main/java/com/godot/game/GodotApp.java
cp android/src/main/java/com/godot/game/DepthEstimator.java android/build/src/main/java/com/godot/game/DepthEstimator.java
cp android/src/main/java/com/godot/game/DiagnosticLog.java android/build/src/main/java/com/godot/game/DiagnosticLog.java
mkdir -p android/build/src/main/java/com/godot/game/diagnostics
cp android/src/main/java/com/godot/game/diagnostics/Log.java android/build/src/main/java/com/godot/game/diagnostics/Log.java
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
bash "$SCRIPT_DIR/tools/build_support/package_android_models.sh" \
  "$SCRIPT_DIR/android/build/nightfallAssets"
LITERT_GPU_AAR="$SCRIPT_DIR/android/libs/litert-gpu-nightfall-1.4.2.aar"
if [ "$USE_STOCK_LITERT" = "1" ]; then
  echo "Using stock-priority LiteRT GPU 1.4.2"
  sed -i '/implementation "androidx.documentfile:documentfile/a\\n    implementation "com.google.ai.edge.litert:litert:1.4.2"\n    implementation "com.google.ai.edge.litert:litert-gpu:1.4.2"' android/build/build.gradle
else
  if [ ! -f "$LITERT_GPU_AAR" ]; then
    echo "Error: low-priority LiteRT GPU AAR not found at $LITERT_GPU_AAR"
    exit 1
  fi
  if ! echo "$NIGHTFALL_LITERT_GPU_AAR_SHA256  $LITERT_GPU_AAR" | sha256sum --check --status; then
    echo "Error: checksum mismatch for $LITERT_GPU_AAR"
    exit 1
  fi
  echo "Using low-priority Nightfall LiteRT GPU 1.4.2"
  sed -i '/implementation "androidx.documentfile:documentfile/a\\n    implementation "com.google.ai.edge.litert:litert:1.4.2"\n    implementation "com.google.ai.edge.litert:litert-gpu-api:1.4.2"\n    implementation files("../libs/litert-gpu-nightfall-1.4.2.aar")' android/build/build.gradle
fi
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
  bash "$SCRIPT_DIR/tools/build_support/deploy_android.sh" "$SCRIPT_DIR/$OUTPUT"
fi
