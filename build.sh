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
    cp "$SCRIPT_DIR/addons/nightfall-stream/bin/linux/libnightfall-stream.linux.template_release.x86_64.so" "$APPDIR/usr/bin/addons/nightfall-stream/bin/linux/"
    cp "$SCRIPT_DIR/addons/godotopenxrvendors/.bin/linux/template_release/x86_64/libgodotopenxrvendors.so" "$APPDIR/usr/bin/addons/godotopenxrvendors/.bin/linux/template_release/x86_64/"
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
mkdir -p android/build/nightfallAssets
cp "$SCRIPT_DIR/android/src/main/assets/midas-midas-v2-w8a8.tflite" android/build/nightfallAssets/
cp "$SCRIPT_DIR/android/src/main/assets/depth-anything-v2-small.tflite" android/build/nightfallAssets/ 2>/dev/null || true
sed -i '/implementation "androidx.documentfile:documentfile/a\\n    implementation "org.tensorflow:tensorflow-lite:2.16.1"' android/build/build.gradle
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
