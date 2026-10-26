#!/usr/bin/env bash
# Minimal LGPL FFmpeg runtime for the optional in-process depth decoder.
# Run inside the Ubuntu 22.04 packaging container; do not bundle GPU drivers.
set -euo pipefail
PREFIX="${1:?installation prefix required}"
WORK="${2:?source/build cache required}"
VERSION=8.0.1
SHA256=05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41
mkdir -p "$WORK" "$PREFIX"
ARCHIVE="$WORK/ffmpeg-$VERSION.tar.xz"
if [[ ! -f "$ARCHIVE" ]]; then
    curl -fL --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$ARCHIVE"
fi
echo "$SHA256  $ARCHIVE" | sha256sum -c --quiet
if [[ ! -d "$WORK/ffmpeg-$VERSION" ]]; then tar -xf "$ARCHIVE" -C "$WORK"; fi
cd "$WORK/ffmpeg-$VERSION"
./configure --prefix="$PREFIX" --disable-autodetect --disable-everything \
    --enable-shared --disable-static --disable-programs --disable-doc --disable-debug \
    --enable-avcodec --enable-avutil --enable-swscale --enable-pthreads \
    --disable-avformat --disable-avfilter --disable-avdevice --disable-swresample \
    --enable-decoder=h264,hevc,av1,libdav1d --enable-parser=h264,hevc,av1 \
    --enable-vaapi --enable-hwaccel=h264_vaapi,hevc_vaapi,av1_vaapi --enable-libdav1d
make -j"$(nproc)"
make install
cp COPYING.LGPLv2.1 "$PREFIX/FFmpeg-COPYING.LGPLv2.1"
# dav1d's ABI differs across distros; libva and the actual VAAPI driver are
# intentionally supplied by the host, matching its graphics stack.
for library in /usr/lib/x86_64-linux-gnu/libdav1d.so.*; do cp -L "$library" "$PREFIX/lib/"; done
cp /usr/share/doc/libdav1d-dev/copyright "$PREFIX/dav1d-copyright"
for library in "$PREFIX"/lib/*.so.*; do patchelf --set-rpath '$ORIGIN' "$library"; done
