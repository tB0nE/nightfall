#!/usr/bin/env bash
# Minimal LGPL FFmpeg 8 runtime for Meteor's in-process depth decoder on macOS, with
# VideoToolbox hardware decoding. The macOS counterpart of build_ffmpeg_runtime.sh.
#
#   meteor/tools/build_ffmpeg_runtime_macos.sh [prefix] [work dir]
#
# Defaults put the libraries in meteor/target/ffmpeg/lib, where a development build looks
# (METEOR_FFMPEG_DIR), and build_macos_app.sh copies them into Meteor.app's Contents/lib.
# The libraries name each other through @loader_path, so they work from any folder.
set -euo pipefail
METEOR="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${1:-$METEOR/target/ffmpeg}"
WORK="${2:-$METEOR/target/ffmpeg-build}"
VERSION=8.0.1
SHA256=05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
mkdir -p "$WORK" "$PREFIX"
ARCHIVE="$WORK/ffmpeg-$VERSION.tar.xz"
if [[ ! -f "$ARCHIVE" ]]; then
  curl -fL --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$ARCHIVE"
fi
echo "$SHA256  $ARCHIVE" | shasum -a 256 -c --quiet
if [[ ! -d "$WORK/ffmpeg-$VERSION" ]]; then tar -xf "$ARCHIVE" -C "$WORK"; fi
cd "$WORK/ffmpeg-$VERSION"
# AV1 decodes only in hardware here (VideoToolbox, M3 and later): no dav1d to bundle.
./configure --prefix="$PREFIX" --install-name-dir=@loader_path \
  --extra-cflags="-mmacosx-version-min=14.2" --extra-ldflags="-mmacosx-version-min=14.2" \
  --disable-autodetect --disable-everything \
  --enable-shared --disable-static --disable-programs --disable-doc --disable-debug \
  --enable-avcodec --enable-avutil --enable-swscale --enable-pthreads \
  --disable-avformat --disable-avfilter --disable-avdevice --disable-swresample \
  --enable-decoder=h264,hevc,av1 --enable-parser=h264,hevc,av1 \
  --enable-videotoolbox --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox,av1_videotoolbox
make -j"$(sysctl -n hw.ncpu)"
make install
cp COPYING.LGPLv2.1 "$PREFIX/FFmpeg-COPYING.LGPLv2.1"
# Only the libraries, by their versioned names, are needed at run time.
rm -rf "$PREFIX/include" "$PREFIX/lib/pkgconfig" "$PREFIX/share"
for library in "$PREFIX"/lib/*.dylib; do
  [[ -L "$library" ]] || codesign --force --sign - "$library"
done
echo "FFmpeg $VERSION runtime in $PREFIX/lib"
