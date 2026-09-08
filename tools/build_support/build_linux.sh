#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <linux|appimage> <output filename>" >&2
  exit 1
fi

TOOL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$TOOL_DIR/../.." && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=native_xr_versions.sh
source "$TOOL_DIR/native_xr_versions.sh"

PLATFORM="$1"
OUTPUT="$2"
if [[ "$PLATFORM" != "linux" && "$PLATFORM" != "appimage" ]]; then
  echo "Error: platform must be linux or appimage" >&2
  exit 1
fi
GODOT="${NIGHTFALL_GODOT_EDITOR:?Set NIGHTFALL_GODOT_EDITOR to a Godot 4.7 executable}"
GODOT_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/godot"
GODOT_TEMPLATE_DIR="${NIGHTFALL_GODOT_TEMPLATE_DIR:-$GODOT_DATA_HOME/export_templates/$NIGHTFALL_GODOT_TEMPLATE_VERSION}"
LINUX_TEMPLATE="$GODOT_TEMPLATE_DIR/linux_release.x86_64"

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
