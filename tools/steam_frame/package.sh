#!/usr/bin/env bash
# Package a release ARM64 build for extraction and adding the launcher to Steam.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="${1:?Usage: package.sh VERSION}"
[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid version' >&2; exit 1; }
CACHE="$ROOT/.build-cache/steam-frame-preview"
GODOT="${NIGHTFALL_GODOT_EDITOR:-$HOME/Applications/Godot_v4.7-stable_linux.x86_64}"
TEMPLATE="${NIGHTFALL_GODOT_TEMPLATE_DIR:-$HOME/.local/share/godot/export_templates/4.7.stable}/linux_release.arm64"
LIB="$CACHE/native/bin/linux/libnightfall-stream.linux.template_release.arm64.so"
VENDOR="$ROOT/addons/godotopenxrvendors/.bin/linux/template_release/arm64/libgodotopenxrvendors.so"
NAME="Nightfall-SteamFrame-${VERSION}-arm64"
DEST="$CACHE/package/$NAME"
for file in "$TEMPLATE" "$LIB" "$VENDOR"; do test -s "$file" || { echo "Missing $file" >&2; exit 1; }; done
mkdir -p "$DEST/addons/nightfall-stream/bin/linux" "$DEST/addons/godotopenxrvendors/.bin/linux/template_release/arm64"
cp "$TEMPLATE" "$DEST/nightfall"
cp "$LIB" "$DEST/addons/nightfall-stream/bin/linux/"
cp "$ROOT/addons/nightfall-stream/bin/nightfall-stream.gdextension" "$DEST/addons/nightfall-stream/bin/"
cp "$VENDOR" "$DEST/addons/godotopenxrvendors/.bin/linux/template_release/arm64/"
cp "$ROOT/addons/godotopenxrvendors/plugin.gdextension" "$DEST/addons/godotopenxrvendors/"
cp "$ROOT/tools/steam_frame/launch-from-steam.sh" "$DEST/"
cp "$ROOT/tools/steam_frame/PACKAGE-README.md" "$DEST/README.md"
cp "$ROOT/LICENSE" "$DEST/LICENSE"
mkdir -p "$DEST/third-party-licenses"
for license in "$CACHE/native/vcpkg_installed/arm64-linux/share/"*/copyright; do
  test ! -f "$license" || cp "$license" "$DEST/third-party-licenses/$(basename "$(dirname "$license")").txt"
done
cp "$ROOT/licences/godot-openxr-vendors.txt" "$DEST/third-party-licenses/godotopenxrvendors.txt"
status=0
"$GODOT" --headless --xr-mode off --path "$ROOT" --export-pack NightfallSteamFrame "$DEST/nightfall.pck" || status=$?
test -s "$DEST/nightfall.pck"
[[ "$status" == 0 || "$status" == 134 ]] || exit "$status"
# Validate exported GDScript on the host; this does not validate ARM execution.
"$GODOT" --headless --xr-mode off --main-pack "$DEST/nightfall.pck" --script res://test/test_app_settings.gd
chmod +x "$DEST/nightfall" "$DEST/launch-from-steam.sh"
printf '%s\n' "Version: $VERSION" "Source: $(git -C "$ROOT" rev-parse HEAD)" "Working tree changes: $(git -C "$ROOT" diff --stat | tail -n 1)" > "$DEST/BUILD.txt"
mkdir -p "$CACHE/artifacts"
tar -C "$CACHE/package" -czf "$CACHE/artifacts/$NAME.tar.gz" "$NAME"
(cd "$CACHE/artifacts" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
printf 'Package: %s\n' "$CACHE/artifacts/$NAME.tar.gz"
