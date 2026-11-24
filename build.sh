#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PRESET="NightfallDev"
OUTPUT="Nightfall-Android-arm64-v8a-debug.apk"
BUILD_KIND="debug"
PLATFORM="android"
USE_STOCK_LITERT=0
VERSION=""
STORE=0
BUILD_NUMBER=""

while [[ "$#" -gt 0 ]]; do
  arg="$1"
  shift
  case "$arg" in
    --release) PRESET="NightfallRelease"; BUILD_KIND="release"; OUTPUT="Nightfall-Android-arm64-v8a.apk" ;;
    --dev)     PRESET="NightfallRelease"; BUILD_KIND="dev";     OUTPUT="Nightfall-Android-arm64-v8a-dev.apk" ;;
    --debug)   PRESET="NightfallDev";     BUILD_KIND="debug";   OUTPUT="Nightfall-Android-arm64-v8a-debug.apk" ;;
    --store)   STORE=1 ;;
    --build)
      [[ "$#" -gt 0 ]] || { echo "--build needs a number, e.g. --build 1"; exit 1; }
      BUILD_NUMBER="$1"
      shift ;;
    --version)
      [[ "$#" -gt 0 ]] || { echo "--version needs a value, e.g. --version 0.7.12"; exit 1; }
      VERSION="${1#v}"
      shift ;;
    --linux)   PLATFORM="linux"; OUTPUT="Nightfall-Linux-x86_64" ;;
    --appimage) PLATFORM="appimage"; OUTPUT="Nightfall-x86_64.AppImage" ;;
    --stock-litert) USE_STOCK_LITERT=1 ;;
    --install) INSTALL=1 ;;
    --help|-h)
      echo "Usage: $0 [--debug|--dev|--release [--store] [--version X.Y.Z] [--build N]] [--linux|--appimage] [--stock-litert] [--install]"
      echo "  --debug     Export debug APK (default)"
      echo "  --dev       Export a release-signed APK for testing. It keeps the last release's"
      echo "              version code, so each dev build replaces the previous one"
      echo "  --release   Export release APK (requires .env keystore config). Its version comes"
      echo "              from the tag on HEAD (vX.Y.Z), or from --version"
      echo "  --store     With --release: the Meta Horizon Store build (entitlement check on,"
      echo "              profiling off). Same package and key as the GitHub APK"
      echo "  --build N   With --release: build number 0-99 (default 0), for uploading the same"
      echo "              version to the store again"
      echo "  --linux     Export Linux x86_64 binary"
      echo "  --appimage  Export Linux x86_64 AppImage (implies --release for Linux)"
      echo "  --stock-litert  Use stock-priority LiteRT GPU instead of the default low-priority Quest build"
      echo "  --install   Install APK via adb after export (Android only)"
      exit 0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done
if [[ -n "$VERSION" && "$BUILD_KIND" != "release" ]]; then
  echo "--version only applies to --release; dev and debug builds take the last release's version"
  exit 1
fi
if [[ ( "$STORE" == 1 || -n "$BUILD_NUMBER" ) && ( "$BUILD_KIND" != "release" || "$PLATFORM" != "android" ) ]]; then
  echo "--store and --build only apply to Android --release builds"
  exit 1
fi
if [[ "$STORE" == 1 ]]; then
  OUTPUT="Nightfall-Android-arm64-v8a-store.apk"
fi

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
    NIGHTFALL_BUILD_KIND="$BUILD_KIND" \
    NIGHTFALL_VERSION="$VERSION" \
    NIGHTFALL_BUILD_NUMBER="${BUILD_NUMBER:-0}" \
    NIGHTFALL_STORE="$STORE" \
    bash "$SCRIPT_DIR/tools/build_support/build_android.sh" "$PRESET" "$OUTPUT"
fi
