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
LINUX_EDITOR_SO="$SCRIPT_DIR/addons/nightfall-stream/bin/linux/libnightfall-stream.linux.template_debug.x86_64.so"
LINUX_VENDOR_SO="$SCRIPT_DIR/addons/godotopenxrvendors/.bin/linux/template_release/x86_64/libgodotopenxrvendors.so"
LINUX_VENDOR_DESCRIPTOR="$SCRIPT_DIR/addons/godotopenxrvendors/plugin.gdextension"
LINUX_DEPTH_MODELS=(
  "$SCRIPT_DIR/models/midas-midas-v2-w8a8.tflite"
  "$SCRIPT_DIR/models/midas-v21-small-192-int8.tflite"
  "$SCRIPT_DIR/models/depth-anything-v2-small-252.tflite"
  "$SCRIPT_DIR/models/midas-v21-small-256-vulkan.ncnn.param"
  "$SCRIPT_DIR/models/midas-v21-small-256-vulkan.ncnn.bin"
  "$SCRIPT_DIR/models/midas-v21-small-192-vulkan.ncnn.param"
  "$SCRIPT_DIR/models/midas-v21-small-192-vulkan.ncnn.bin"
  "$SCRIPT_DIR/models/depth-anything-v2-252-vulkan.ncnn.param"
  "$SCRIPT_DIR/models/depth-anything-v2-252-vulkan.ncnn.bin"
  "$SCRIPT_DIR/models/zipdepth-base-384-vulkan.ncnn.param"
  "$SCRIPT_DIR/models/zipdepth-base-384-vulkan.ncnn.bin"
  "$SCRIPT_DIR/models/zipdepth-base-256-vulkan.ncnn.param"
  "$SCRIPT_DIR/models/zipdepth-base-256-vulkan.ncnn.bin"
)

if [ ! -f "$LINUX_TEMPLATE" ]; then
  echo "Error: Linux template not found at $LINUX_TEMPLATE"
  exit 1
fi
if [ ! -f "$LINUX_VENDOR_SO" ] || [ ! -f "$LINUX_VENDOR_DESCRIPTOR" ]; then
  echo "Error: Linux GodotOpenXRVendors plugin is incomplete" >&2
  echo "Expected $LINUX_VENDOR_SO and $LINUX_VENDOR_DESCRIPTOR" >&2
  exit 1
fi
for model in "${LINUX_DEPTH_MODELS[@]}"; do
  if [ ! -f "$model" ]; then
    echo "Error: Linux depth model not found at $model" >&2
    echo "See models/README.md for the required model manifest." >&2
    exit 1
  fi
done

echo "Building Linux .so in Ubuntu 22.04 Docker container (glibc 2.35 compat)..."
bash "$SCRIPT_DIR/docker-build-linux.sh"

if [ ! -f "$LINUX_SO" ]; then
  echo "Error: Linux .so build failed"
  exit 1
fi
# Godot's headless editor selects the debug GDExtension mapping even when it
# exports a release pack. A fresh Linux worktree only has the release library.
if [ ! -e "$LINUX_EDITOR_SO" ]; then
  ln -s "$(basename "$LINUX_SO")" "$LINUX_EDITOR_SO"
fi

LINUX_BINARY="$SCRIPT_DIR/Nightfall-Linux-x86_64"
PCK_PATH="$SCRIPT_DIR/Nightfall-Linux.pck"
APPDIR="$SCRIPT_DIR/Nightfall.AppDir"
rm -f "$PCK_PATH" "$LINUX_BINARY"
rm -rf "$APPDIR"

echo "Exporting PCK for Linux..."
export_status=0
"$GODOT" --headless --path "$SCRIPT_DIR" --export-pack NightfallLinux "$PCK_PATH" 2>&1 || export_status=$?

if [ ! -s "$PCK_PATH" ]; then
  echo "Error: PCK export failed (editor exit status $export_status)"
  exit 1
fi
if [ "$export_status" -ne 0 ] && [ "$export_status" -ne 134 ]; then
  echo "Error: Godot exited with unexpected status $export_status during PCK export"
  exit 1
fi
# Godot 4.7 can abort with status 134 while closing the headless editor after
# savepack has completed. Accept that specific post-export failure only when a
# fresh pack exists and its bundled settings test loads and passes.
if ! "$GODOT" --headless --xr-mode off --main-pack "$PCK_PATH" --script res://test/test_app_settings.gd; then
  echo "Error: exported Linux PCK did not pass validation"
  exit 1
fi
if [ "$export_status" -eq 134 ]; then
  echo "Warning: Godot aborted after writing the PCK; validated pack will be used"
fi

echo "Assembling Linux binary from template + PCK..."
cp "$LINUX_TEMPLATE" "$LINUX_BINARY"
cat "$PCK_PATH" >> "$LINUX_BINARY"
chmod +x "$LINUX_BINARY"

SIZE=$(ls -lh "$LINUX_BINARY" | awk '{print $5}')
echo "Assembled Linux binary ($SIZE)"

# Native AI-3D depth on Linux - midas_depth_engine.cpp
# resolves its model directory relative to the running executable's own path
# (OS::get_executable_path()'s base dir + "/depth_models"), NOT through
# Godot's res:///PCK. The Linux preset intentionally does not include models/;
# they remain loose files so the native depth engine can open them directly.
# Same "loose files next to the binary" pattern as the .so/AAR copies below.
# Models live in models/ (gitignored, not committed - see models/README.md
# for the full manifest and how to obtain each file) rather than
# android/src/main/assets/ (2026-08-24) - both Android and Linux now pull
# from the same single source directory instead of Android's assets folder
# doing double duty as the canonical location for a non-Android platform.
mkdir -p "$SCRIPT_DIR/depth_models"
cp "${LINUX_DEPTH_MODELS[@]}" "$SCRIPT_DIR/depth_models/"

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
  cp "$LINUX_VENDOR_SO" "$APPDIR/usr/bin/addons/godotopenxrvendors/.bin/linux/template_release/x86_64/"
  cp "$SCRIPT_DIR/depth_models/"*.tflite "$APPDIR/usr/bin/depth_models/"
  cp "$SCRIPT_DIR/depth_models/"*.ncnn.param "$APPDIR/usr/bin/depth_models/"
  cp "$SCRIPT_DIR/depth_models/"*.ncnn.bin "$APPDIR/usr/bin/depth_models/"
  cp "$LINUX_VENDOR_DESCRIPTOR" "$APPDIR/usr/bin/addons/godotopenxrvendors/"
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
