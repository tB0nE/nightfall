#!/usr/bin/env bash
# Packages Nightfall Meteor.app (from build_macos_app.sh) as a drag-to-Applications disk image:
#
#   meteor/tools/build_macos_dmg.sh
#   -> meteor/target/macos/Nightfall-Meteor-<version>-macos-arm64.dmg
#
# For distribution, build the app and the image with a Developer ID and notarise them:
#
#   export MACOS_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   meteor/tools/build_macos_app.sh <Vibepollo>      # hardened runtime, timestamped
#   MACOS_NOTARY_PROFILE=<profile> meteor/tools/build_macos_dmg.sh   # notarises the image
#
# The profile holds the notary credentials, stored once with
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>
# Without MACOS_SIGN_IDENTITY the image is for this Mac only: Gatekeeper rejects the app
# elsewhere.
set -euo pipefail

METEOR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$METEOR/target/macos/Nightfall Meteor.app"
[[ -d "$APP" ]] || { echo "Build the app first: meteor/tools/build_macos_app.sh <Vibepollo checkout>" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$METEOR/target/macos/Nightfall-Meteor-$VERSION-macos-$(uname -m).dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE:?}"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Nightfall Meteor" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

if [[ -n "${MACOS_SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$MACOS_SIGN_IDENTITY" "$DMG"
  if [[ -n "${MACOS_NOTARY_PROFILE:-}" ]]; then
    # Notarising the image covers the app inside it; stapling lets it open offline.
    xcrun notarytool submit "$DMG" --keychain-profile "$MACOS_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  else
    echo "Signed but not notarised: set MACOS_NOTARY_PROFILE to notarise" >&2
  fi
fi
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
