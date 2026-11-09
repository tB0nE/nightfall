#!/usr/bin/env bash
# Builds Nightfall Meteor.app for macOS, with Meteor-Vibepollo inside.
#
#   meteor/tools/build_macos_app.sh <Vibepollo checkout>
#
# The Vibepollo checkout must already be built and installed into build/stage
# (see docs/plans/active/meteor-macos.md). Output:
#   meteor/target/macos/Nightfall Meteor.app
#
# The host sits in Contents/Resources/host: bin/meteor-vibepollo, its dylibs in
# Frameworks (its load paths are @executable_path/../Frameworks) and its web UI
# in Resources/assets (found from its working directory, bin/). Meteor.app is the
# responsible process for the host, so Screen Recording, Accessibility and Local
# Network are granted to Meteor once. Signed ad hoc unless MACOS_SIGN_IDENTITY is set.
set -euo pipefail

VIBEPOLLO="${1:?usage: $0 <Vibepollo checkout>}"
METEOR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$VIBEPOLLO/build/stage/Vibepollo.app/Contents"
[[ -x "$STAGE/MacOS/Vibepollo" || -x "$STAGE/MacOS/Vibepollo-2.0.0" ]] || {
  echo "No staged Vibepollo in $STAGE: build it and run cmake --install build --prefix \$PWD/build/stage" >&2; exit 1; }

VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$METEOR/Cargo.toml" | head -1)"
APP="$METEOR/target/macos/Nightfall Meteor.app"

cargo build --manifest-path "$METEOR/Cargo.toml" --release --locked --no-default-features

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/host/bin" "$APP/Contents/Resources/host/Resources"
cp "$METEOR/target/release/nightfall-meteor" "$APP/Contents/MacOS/nightfall-meteor"

HOST_BINARY="$(find "$STAGE/MacOS" -maxdepth 1 -type f -name 'Vibepollo-*' | head -1)"
cp "$HOST_BINARY" "$APP/Contents/Resources/host/bin/meteor-vibepollo"
cp -R "$STAGE/Frameworks" "$APP/Contents/Resources/host/Frameworks"
cp -R "$STAGE/Resources/assets" "$APP/Contents/Resources/host/Resources/assets"

# Models shipped beside the binary (../share/nightfall-meteor/models from MacOS/).
if [[ -n "${METEOR_MODELS_DIR:-}" ]]; then
  mkdir -p "$APP/Contents/share/nightfall-meteor/models"
  cp "$METEOR_MODELS_DIR"/*.ncnn.* "$APP/Contents/share/nightfall-meteor/models/" 2>/dev/null || true
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.tb0ne.nightfall.meteor</string>
  <key>CFBundleName</key><string>Nightfall Meteor</string>
  <key>CFBundleDisplayName</key><string>Nightfall Meteor</string>
  <key>CFBundleExecutable</key><string>nightfall-meteor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.2</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <!-- A menu-bar app: no Dock icon. -->
  <key>LSUIElement</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Nightfall Meteor streams this Mac's screens to your Nightfall headset over the local network.</string>
  <key>NSBonjourServices</key>
  <array><string>_nvstream._tcp</string></array>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Nightfall Meteor captures your screens to stream them to your Nightfall headset.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Nightfall Meteor captures this Mac's sound to stream it to your Nightfall headset.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Nightfall Meteor streams audio to your Nightfall headset.</string>
</dict>
</plist>
PLIST

IDENTITY="${MACOS_SIGN_IDENTITY:--}"
# Inside out: libraries, the host, then the app.
find "$APP/Contents/Resources/host/Frameworks" -name '*.dylib' -exec codesign --force --sign "$IDENTITY" {} \;
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/host/bin/meteor-vibepollo"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
