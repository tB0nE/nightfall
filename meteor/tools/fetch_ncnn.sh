#!/bin/sh
# Downloads ncnn's prebuilt shared library (Vulkan, BSD-3) into target/ncnn,
# where a development build of Meteor finds it (see src/ncnn.rs).
set -eu

VERSION=20260526
NAME="ncnn-$VERSION-ubuntu-2404-shared"
cd "$(dirname "$0")/.."
DEST=target/ncnn
TMP=$(mktemp -d)
trap 'rm -rf "${TMP:?}"' EXIT

curl -fsSL --retry 3 -o "$TMP/ncnn.zip" "https://github.com/Tencent/ncnn/releases/download/$VERSION/$NAME.zip"
unzip -q "$TMP/ncnn.zip" -d "$TMP"
rm -rf "${DEST:?}"
mkdir -p "$DEST"
cp -a "$TMP/$NAME/lib" "$TMP/$NAME/include" "$DEST/"
echo "ncnn $VERSION in $DEST/lib"
