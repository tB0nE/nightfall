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
# Network are granted to Meteor once. Signed with MACOS_SIGN_IDENTITY, else a stable local
# self-signed certificate, so those grants survive rebuilds.
set -euo pipefail

VIBEPOLLO="${1:?usage: $0 <Vibepollo checkout>}"
METEOR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$VIBEPOLLO/build/stage/Vibepollo.app/Contents"
[[ -x "$STAGE/MacOS/Vibepollo" || -x "$STAGE/MacOS/Vibepollo-2.0.0" ]] || {
  echo "No staged Vibepollo in $STAGE: build it and run cmake --install build --prefix \$PWD/build/stage" >&2; exit 1; }

# METEOR_RELEASE_VERSION names a release (e.g. 0.9.0) without changing Cargo.toml; Meteor,
# Info.plist and the disk image all carry it.
VERSION="${METEOR_RELEASE_VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' "$METEOR/Cargo.toml" | head -1)}"
export METEOR_RELEASE_VERSION="$VERSION"
APP="$METEOR/target/macos/Nightfall Meteor.app"

cargo build --manifest-path "$METEOR/Cargo.toml" --release --locked --no-default-features

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/host/bin" "$APP/Contents/Resources/host/Resources"
cp "$METEOR/target/release/nightfall-meteor" "$APP/Contents/MacOS/nightfall-meteor"

HOST_BINARY="$(find "$STAGE/MacOS" -maxdepth 1 -type f -name 'Vibepollo-*' | head -1)"
cp "$HOST_BINARY" "$APP/Contents/Resources/host/bin/meteor-vibepollo"
cp -R "$STAGE/Frameworks" "$APP/Contents/Resources/host/Frameworks"
cp -R "$STAGE/Resources/assets" "$APP/Contents/Resources/host/Resources/assets"

# Host depth: ncnn + MoltenVK (tools/build_ncnn_macos.sh) and the FFmpeg 8 decoder runtime
# (tools/build_ffmpeg_runtime_macos.sh) in Contents/lib, which Meteor searches as ../lib.
# Without them Meteor still runs, as a plain proxy.
mkdir -p "$APP/Contents/lib"
for runtime in "$METEOR/target/ncnn/lib" "$METEOR/target/ffmpeg/lib"; do
  if compgen -G "$runtime/*.dylib" >/dev/null; then
    cp -a "$runtime"/*.dylib "$APP/Contents/lib/"
  else
    echo "warning: no $runtime; Meteor.app will have no host depth" >&2
  fi
done
# Vulkan frame preparation/post-processing, built by build.rs against target/ncnn.
VULKAN_PROCESSING="$(ls -t "$METEOR"/target/release/build/nightfall-meteor-*/out/libmeteor_vda_vulkan.dylib 2>/dev/null | head -1)"
if [[ -n "$VULKAN_PROCESSING" ]]; then
  cp "$VULKAN_PROCESSING" "$APP/Contents/lib/"
else
  echo "warning: no libmeteor_vda_vulkan.dylib; depth processing will use the CPU" >&2
fi
for notice in "$METEOR/target/ncnn/ncnn-LICENSE.txt" "$METEOR/target/ffmpeg/FFmpeg-COPYING.LGPLv2.1"; do
  [[ -f "$notice" ]] && cp "$notice" "$APP/Contents/lib/"
done

# Models shipped beside the binary (../share/nightfall-meteor/models from MacOS/).
MODELS="${METEOR_MODELS_DIR:-$METEOR/target/models-macos}"
if compgen -G "$MODELS/*.ncnn.param" >/dev/null; then
  mkdir -p "$APP/Contents/share/nightfall-meteor/models"
  cp "$MODELS"/*.ncnn.* "$APP/Contents/share/nightfall-meteor/models/"
else
  echo "warning: no EdgePad models in $MODELS; host depth needs them in the models folder" >&2
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

# macOS grants Screen Recording and Accessibility to an app's signing identity. An ad hoc
# signature's identity is its hash, so every rebuild would lose them. Without
# MACOS_SIGN_IDENTITY, sign with a self-signed local certificate kept in its own keychain
# file (not the login keychain). Delete DEV_SIGNING to remove it.
SIGN=(codesign --force)
ENTITLEMENTS="$METEOR/tools/macos/Meteor.entitlements"
# Developer ID distribution requires the hardened runtime; MACOS_HARDENED=1 tries it with the
# local certificate, to catch what it breaks before a real identity is involved.
HARDENED=()
if [[ -n "${MACOS_SIGN_IDENTITY:-}" ]]; then
  SIGN+=(--sign "$MACOS_SIGN_IDENTITY" --timestamp)
  HARDENED=(--options runtime --entitlements "$ENTITLEMENTS")
elif [[ "${MACOS_HARDENED:-}" == 1 ]]; then
  # Library validation only accepts libraries from the app's own Apple team, and a self-signed
  # certificate has no team ID, so this local test turns that one check off. A Developer ID
  # signs every file with one team ID, and keeps it on.
  LOCAL_ENTITLEMENTS="$(mktemp -t meteor-entitlements).plist"
  cp "$ENTITLEMENTS" "$LOCAL_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$LOCAL_ENTITLEMENTS"
  HARDENED=(--options runtime --entitlements "$LOCAL_ENTITLEMENTS")
fi
if [[ -z "${MACOS_SIGN_IDENTITY:-}" ]]; then
  DEV_SIGNING="$HOME/Library/Application Support/Nightfall Meteor Dev Signing"
  KEYCHAIN="$DEV_SIGNING/signing.keychain-db"
  NAME="Nightfall Meteor Local Signing"
  if [[ ! -f "$KEYCHAIN" ]]; then
    mkdir -p "$DEV_SIGNING"; chmod 700 "$DEV_SIGNING"
    /usr/bin/openssl rand -hex 24 > "$DEV_SIGNING/keychain-password"; chmod 600 "$DEV_SIGNING/keychain-password"
    WORK="$(mktemp -d)"
    cat > "$WORK/cert.conf" <<CONF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.conf" \
      -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" -passout pass:local
    security create-keychain -p "$(cat "$DEV_SIGNING/keychain-password")" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"   # no auto-lock
    security import "$WORK/id.p12" -k "$KEYCHAIN" -P local -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$DEV_SIGNING/keychain-password")" "$KEYCHAIN" >/dev/null
    rm -rf "$WORK"
    echo "Made the local signing certificate in $DEV_SIGNING"
  fi
  security unlock-keychain -p "$(cat "$DEV_SIGNING/keychain-password")" "$KEYCHAIN"
  HASH="$(security find-certificate -c "$NAME" -Z "$KEYCHAIN" | awk '/SHA-1 hash:/{print $3}')"
  # codesign ignores an untrusted (self-signed) identity unless its keychain is in the user's
  # search list. Add it for signing only, and always put the user's list back.
  ORIGINAL_KEYCHAINS=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
    [[ -n "$line" ]] && ORIGINAL_KEYCHAINS+=("$line")
  done < <(security list-keychains -d user)
  restore_keychains() { security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"; }
  trap restore_keychains EXIT
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$KEYCHAIN"
  SIGN+=(--sign "$HASH")
fi
# Inside out: libraries, the host, then the app.
find "$APP/Contents/Resources/host/Frameworks" "$APP/Contents/lib" -type f -name '*.dylib' -exec "${SIGN[@]}" {} \;
"${SIGN[@]}" ${HARDENED[@]+"${HARDENED[@]}"} "$APP/Contents/Resources/host/bin/meteor-vibepollo"
"${SIGN[@]}" ${HARDENED[@]+"${HARDENED[@]}"} "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
