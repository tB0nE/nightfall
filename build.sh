#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

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
# metadata. Android still receives the separately built patched runtime.
DEFAULT_GODOT_EDITOR="/var/home/tyrone/Applications/Godot_v4.7-stable_linux.x86_64"
if command -v godot >/dev/null 2>&1; then
  DEFAULT_GODOT_EDITOR="$(command -v godot)"
fi
GODOT="${NIGHTFALL_GODOT_EDITOR:-$DEFAULT_GODOT_EDITOR}"

if [[ "$PLATFORM" == "linux" || "$PLATFORM" == "appimage" ]]; then
  NIGHTFALL_GODOT_EDITOR="$GODOT" \
    bash "$SCRIPT_DIR/tools/build_support/build_linux.sh" "$PLATFORM" "$OUTPUT"
else
  NIGHTFALL_GODOT_EDITOR="$GODOT" \
    NIGHTFALL_USE_STOCK_LITERT="$USE_STOCK_LITERT" \
    NIGHTFALL_INSTALL="${INSTALL:-0}" \
    bash "$SCRIPT_DIR/tools/build_support/build_android.sh" "$PRESET" "$OUTPUT"
fi
