#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=tools/build_support/native_xr_versions.sh
source "$SCRIPT_DIR/tools/build_support/native_xr_versions.sh"

PRESET="NightfallDev"
OUTPUT="Nightfall-Android-arm64-v8a-debug.apk"
PLATFORM="android"
USE_STOCK_LITERT=0

for arg in "$@"; do
  case "$arg" in
    --release) PRESET="NightfallRelease"; OUTPUT="Nightfall-Android-arm64-v8a.apk" ;;
    --debug)   PRESET="NightfallDev";     OUTPUT="Nightfall-Android-arm64-v8a-debug.apk" ;;
    --linux)   PLATFORM="linux"; OUTPUT="Nightfall-Linux-x86_64" ;;
    --appimage) PLATFORM="appimage"; OUTPUT="Nightfall-x86_64.AppImage" ;;
    --stock-litert) USE_STOCK_LITERT=1 ;;
    --install) INSTALL=1 ;;
    --help|-h)
      echo "Usage: $0 [--debug|--release] [--linux|--appimage] [--stock-litert] [--install]"
      echo "  --debug     Export debug APK (default)"
      echo "  --release   Export release APK (requires .env keystore config)"
      echo "  --linux     Export Linux x86_64 binary"
      echo "  --appimage  Export Linux x86_64 AppImage (implies --release for Linux)"
      echo "  --stock-litert  Use stock-priority LiteRT GPU instead of the default low-priority Quest build"
      echo "  --install   Install APK via adb after export (Android only)"
      exit 0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

# Export with the editor version matching the installed 4.7.stable template
# metadata. The Android runtime library is still the patched engine copied into
# that template; the patched editor is only needed when regenerating the custom
# godot-cpp API used to compile nightfall-xr.
DEFAULT_GODOT_EDITOR="/var/home/tyrone/Applications/Godot_v4.7-stable_linux.x86_64"
if command -v godot >/dev/null 2>&1; then
  DEFAULT_GODOT_EDITOR="$(command -v godot)"
fi
GODOT="${NIGHTFALL_GODOT_EDITOR:-$DEFAULT_GODOT_EDITOR}"
JAVA_HOME="${NIGHTFALL_JAVA_HOME:-${JAVA_HOME:-/home/linuxbrew/.linuxbrew/opt/openjdk@17}}"
GODOT_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/godot"
GODOT_TEMPLATE_DIR="${NIGHTFALL_GODOT_TEMPLATE_DIR:-$GODOT_DATA_HOME/export_templates/$NIGHTFALL_GODOT_TEMPLATE_VERSION}"
TEMPLATES="${NIGHTFALL_ANDROID_SOURCE_TEMPLATE:-$GODOT_TEMPLATE_DIR/android_source.zip}"
LINUX_TEMPLATE_DEBUG="$GODOT_TEMPLATE_DIR/linux_debug.x86_64"
LINUX_TEMPLATE_RELEASE="$GODOT_TEMPLATE_DIR/linux_release.x86_64"

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
