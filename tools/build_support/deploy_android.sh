#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: $0 <APK path>" >&2
  exit 1
fi

APK_PATH="$1"
if [[ ! -f "$APK_PATH" ]]; then
  echo "Error: APK not found at $APK_PATH" >&2
  exit 1
fi
if ! command -v adb >/dev/null 2>&1; then
  echo "Error: adb is required to install an APK" >&2
  exit 1
fi

echo "Installing on device..."
adb install -r "$APK_PATH"
echo "Done!"
