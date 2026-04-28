#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PRESET="NightfallDev"
OUTPUT="Nightfall-Android-arm64-v8a-debug.apk"

for arg in "$@"; do
  case "$arg" in
    --release) PRESET="NightfallRelease"; OUTPUT="Nightfall-Android-arm64-v8a.apk" ;;
    --debug)   PRESET="NightfallDev";     OUTPUT="Nightfall-Android-arm64-v8a-debug.apk" ;;
    --install) INSTALL=1 ;;
    --help|-h)
      echo "Usage: $0 [--debug|--release] [--install]"
      echo "  --debug    Export debug APK (default)"
      echo "  --release  Export release APK (requires .env keystore config)"
      echo "  --install  Install APK via adb after export"
      exit 0 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

GODOT="/var/home/tyrone/.local/share/Steam/steamapps/common/Godot Engine/godot.x11.opt.tools.64"
JAVA_HOME="/home/linuxbrew/.linuxbrew/opt/openjdk@17"
TEMPLATES="/var/home/tyrone/.local/share/Steam/steamapps/common/Godot Engine/editor_data/export_templates/4.6.2.stable/android_source.zip"

CONFIG="export_presets.cfg"
CONFIG_BACKUP="export_presets.cfg.bak"

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
cp ../src/main/java/com/godot/game/GodotApp.java src/main/java/com/godot/game/GodotApp.java
cd "$SCRIPT_DIR"

echo "Exporting $PRESET..."
JAVA_HOME="$JAVA_HOME" "$GODOT" --headless --path "$SCRIPT_DIR" --export-debug "$PRESET" "$SCRIPT_DIR/$OUTPUT" 2>&1

if [ ! -f "$OUTPUT" ]; then
  echo "Error: $OUTPUT not created"
  exit 1
fi

SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
echo "Exported $OUTPUT ($SIZE)"

if [ "${INSTALL:-0}" = "1" ]; then
  echo "Installing on device..."
  adb install -r "$OUTPUT"
  echo "Done!"
fi
