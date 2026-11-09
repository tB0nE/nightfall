#!/usr/bin/env bash
# Builds ncnn for macOS into target/ncnn/lib, where a development build of Meteor finds it
# (src/ncnn.rs) and build_macos_app.sh copies it into Meteor.app's Contents/lib.
#
# ncnn's macOS release is static with hidden symbols, which a dlopen()ed library can't use,
# so this builds the pinned release's source as a shared library (C API, Vulkan). ncnn's
# own loader opens Vulkan at run time; on macOS that is MoltenVK (Vulkan on Metal,
# Apache-2.0; brew install molten-vk), copied beside it and found through @loader_path.
set -euo pipefail

VERSION=20260526
SHA256=754659d6fe65545cf2ef4483ffb84526fea631f8764c44b150f1601d0fb4004b
cd "$(dirname "$0")/.."
DEST=target/ncnn
WORK=target/ncnn-build-macos
MOLTENVK="$(brew --prefix molten-vk 2>/dev/null)/lib/libMoltenVK.dylib"
[[ -f "$MOLTENVK" ]] || { echo "MoltenVK not found: brew install molten-vk" >&2; exit 1; }

mkdir -p "$WORK"
ARCHIVE="$WORK/ncnn-$VERSION-full-source.zip"
if [[ ! -f "$ARCHIVE" ]]; then
  curl -fsSL --retry 3 -o "$ARCHIVE" "https://github.com/Tencent/ncnn/releases/download/$VERSION/ncnn-$VERSION-full-source.zip"
fi
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c --quiet
if [[ ! -d "$WORK/src" ]]; then mkdir -p "$WORK/src" && unzip -q "$ARCHIVE" -d "$WORK/src"; fi

cmake -S "$WORK/src" -B "$WORK/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 -DCMAKE_OSX_ARCHITECTURES="$(uname -m)" \
  -DNCNN_VULKAN=ON -DNCNN_SHARED_LIB=ON -DNCNN_SIMPLEOMP=ON -DNCNN_C_API=ON \
  -DNCNN_BUILD_TOOLS=OFF -DNCNN_BUILD_EXAMPLES=OFF -DNCNN_BUILD_BENCHMARK=OFF -DNCNN_BUILD_TESTS=OFF \
  -DCMAKE_INSTALL_PREFIX="$PWD/$WORK/install" -DCMAKE_INSTALL_RPATH=@loader_path -DCMAKE_INSTALL_NAME_DIR=@rpath
cmake --build "$WORK/build" -j "$(sysctl -n hw.ncpu)"
cmake --install "$WORK/build"

rm -rf "${DEST:?}"
mkdir -p "$DEST/lib"
cp -R "$WORK/install/include" "$DEST/include"
cp -L "$WORK/install/lib/libncnn.1.dylib" "$DEST/lib/libncnn.1.dylib"
# The name build.rs links the Vulkan processing library against (-lncnn).
ln -sfn libncnn.1.dylib "$DEST/lib/libncnn.dylib"
cp -L "$MOLTENVK" "$DEST/lib/libMoltenVK.dylib"
chmod u+w "$DEST/lib/libMoltenVK.dylib"
install_name_tool -id @rpath/libMoltenVK.dylib "$DEST/lib/libMoltenVK.dylib"
cp "$WORK/src/LICENSE.txt" "$DEST/ncnn-LICENSE.txt"
for library in "$DEST"/lib/*.dylib; do codesign --force --sign - "$library"; done
echo "ncnn $VERSION (shared, Vulkan via MoltenVK) in $DEST/lib"
