#!/usr/bin/env bash
# The Godot Meta Toolkit (Meta Platform SDK bindings), for store builds only
# (docs/plans/active/meta-horizon-store.md). It's kept out of res:// so that
# sideload, debug and Linux builds never load or ship it; build_android.sh
# copies it into addons/ for the length of a --store export.
#
# Sourced by build_android.sh:
#   nightfall_meta_toolkit_fetch   downloads and checks the pinned release
#   NIGHTFALL_META_TOOLKIT_ADDON   the unpacked addons/godot_meta_toolkit

NIGHTFALL_META_TOOLKIT_VERSION="1.0.3-stable"
NIGHTFALL_META_TOOLKIT_SHA256="cbd23eb9c0ce6868570aa43a674688d749bafeab6b38027f5a588bb21b27d879"
NIGHTFALL_META_TOOLKIT_URL="https://github.com/godot-sdk-integrations/godot-meta-toolkit/releases/download/$NIGHTFALL_META_TOOLKIT_VERSION/godotmetatoolkitaddon.zip"

nightfall_meta_toolkit_fetch() {
  local root="$1"
  local cache="$root/.build-cache/godot-meta-toolkit/$NIGHTFALL_META_TOOLKIT_VERSION"
  local zip="$cache/godotmetatoolkitaddon.zip"
  NIGHTFALL_META_TOOLKIT_ADDON="$cache/asset/addons/godot_meta_toolkit"
  if [ -f "$NIGHTFALL_META_TOOLKIT_ADDON/toolkit.gdextension" ]; then
    return 0
  fi
  mkdir -p "$cache"
  if [ ! -f "$zip" ]; then
    echo "Downloading Godot Meta Toolkit $NIGHTFALL_META_TOOLKIT_VERSION"
    curl -fL --retry 3 -o "$zip.part" "$NIGHTFALL_META_TOOLKIT_URL" && mv "$zip.part" "$zip" || return 1
  fi
  if ! echo "$NIGHTFALL_META_TOOLKIT_SHA256  $zip" | sha256sum --check --status; then
    echo "Error: checksum mismatch for $zip" >&2
    rm -f "$zip"
    return 1
  fi
  rm -rf "$cache/asset"
  unzip -q "$zip" -d "$cache"
  [ -f "$NIGHTFALL_META_TOOLKIT_ADDON/toolkit.gdextension" ] || { echo "Error: toolkit zip has no toolkit.gdextension" >&2; return 1; }
}
