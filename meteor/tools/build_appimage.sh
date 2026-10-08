#!/usr/bin/env bash
# Builds Nightfall-Meteor-x86_64.AppImage: Meteor (without ONNX Runtime),
# ncnn and EdgePad 512 for Vulkan, about 30 MB. VDA is a download from the
# tray (src/download.rs). See docs/plans/active/meteor-appimage.md.
#
# usage: tools/build_appimage.sh [models folder]
#
# The models folder must hold zipdepth_wide_512x288.ncnn.{param,bin}
# (models/convert_ncnn.py); default ~/.local/share/nightfall-meteor/models.
# Needs podman (or docker) and network access. Output in target/appimage/.
set -euo pipefail

cd "$(dirname "$0")/.."
METEOR="$PWD"
REPO="$(cd .. && pwd)"
MODELS="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/nightfall-meteor/models}"
EDGEPAD=zipdepth_wide_512x288
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"

NCNN_VERSION=20260526
NCNN_ZIP="ncnn-$NCNN_VERSION-ubuntu-2204-shared"
NCNN_SHA256=69174c845eaf0e7b592f1e032b700d1b0ffda2915ebf69ee98b2d87411578d30
NCNN_LICENSE_SHA256=7c974bac98848df46be1af5bdaa3c3c9c01f6082a90f55caeb7f60c6208aa255
MAX_BYTES=$((100 * 1000 * 1000))

OUT="$METEOR/target/appimage"
WORK="$OUT/work"
APPDIR="$WORK/AppDir"
IMAGE=nightfall-meteor-appimage
ENGINE="$(command -v podman || command -v docker)"

for f in "$MODELS/$EDGEPAD.ncnn.param" "$MODELS/$EDGEPAD.ncnn.bin"; do
    [[ -f "$f" ]] || { echo "Missing $f (see models/README.md)" >&2; exit 1; }
done
grep -q "^Input .* 0=512 1=288 2=3" "$MODELS/$EDGEPAD.ncnn.param" \
    || { echo "$EDGEPAD.ncnn.param has no input size; convert it with models/convert_ncnn.py" >&2; exit 1; }

mkdir -p "$OUT/cargo-target" "$OUT/cargo-registry" "$WORK"
rm -rf "${APPDIR:?}" "${WORK:?}/stage"
mkdir -p "$WORK/stage"

echo "== Building Meteor in Ubuntu 22.04"
"$ENGINE" build -q -t "$IMAGE" -f tools/appimage/Containerfile tools/appimage >/dev/null
"$ENGINE" run --rm --userns=keep-id --security-opt label=disable \
    -v "$METEOR:/src:ro" \
    -v "$OUT/cargo-target:/target" \
    -v "$OUT/cargo-registry:/opt/cargo/registry" \
    -v "$WORK/stage:/stage" \
    -e NCNN_ZIP="$NCNN_ZIP" -e NCNN_VERSION="$NCNN_VERSION" \
    -e NCNN_SHA256="$NCNN_SHA256" -e NCNN_LICENSE_SHA256="$NCNN_LICENSE_SHA256" \
    "$IMAGE" bash -euo pipefail -c '
cd /src
cargo build --release --locked --no-default-features --target-dir /target
cp /target/release/nightfall-meteor /stage/
cargo about generate --no-default-features --fail -c tools/appimage/about.toml tools/appimage/about.hbs > /stage/crates.txt

cd /tmp
curl -fsSL -o ncnn.zip "https://github.com/Tencent/ncnn/releases/download/$NCNN_VERSION/$NCNN_ZIP.zip"
echo "$NCNN_SHA256  ncnn.zip" | sha256sum -c --quiet
curl -fsSL -o ncnn-LICENSE.txt "https://raw.githubusercontent.com/Tencent/ncnn/$NCNN_VERSION/LICENSE.txt"
echo "$NCNN_LICENSE_SHA256  ncnn-LICENSE.txt" | sha256sum -c --quiet
unzip -q ncnn.zip
cp "$NCNN_ZIP/lib/libncnn.so.1."* /stage/libncnn.so.1
cp ncnn-LICENSE.txt /stage/
# ncnn needs libgomp, which not every distribution installs; it finds the
# copy next to it.
cp /usr/lib/x86_64-linux-gnu/libgomp.so.1 /stage/
patchelf --set-rpath "\$ORIGIN" /stage/libncnn.so.1
echo "glibc needed: $(objdump -T /stage/nightfall-meteor /stage/libncnn.so.1 /stage/libgomp.so.1 | grep -o "GLIBC_[0-9.]*" | sort -uV | tail -1)"
'

echo "== Assembling the AppDir"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/nightfall-meteor/models" \
    "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/732x732/apps" "$APPDIR/usr/share/doc/nightfall-meteor"
install -m755 "$WORK/stage/nightfall-meteor" "$APPDIR/usr/bin/"
install -m644 "$WORK/stage/libncnn.so.1" "$WORK/stage/libgomp.so.1" "$APPDIR/usr/lib/"
install -m644 "$MODELS/$EDGEPAD.ncnn.param" "$MODELS/$EDGEPAD.ncnn.bin" "$APPDIR/usr/share/nightfall-meteor/models/"
install -m755 tools/appimage/AppRun "$APPDIR/AppRun"
install -m644 tools/appimage/nightfall-meteor.desktop "$APPDIR/"
install -m644 tools/appimage/nightfall-meteor.desktop "$APPDIR/usr/share/applications/"
install -m644 "$REPO/src/assets/nightfall_icon_v1.png" "$APPDIR/nightfall-meteor.png"
install -m644 "$REPO/src/assets/nightfall_icon_v1.png" "$APPDIR/usr/share/icons/hicolor/732x732/apps/nightfall-meteor.png"
install -m644 "$REPO/LICENSE" "$APPDIR/usr/share/doc/nightfall-meteor/LICENSE"
{
    echo "Nightfall Meteor $VERSION is free software under the GNU GPL v3 (LICENSE)."
    echo "It includes the components below, under their own licences."
    echo
    echo "- ncnn $NCNN_VERSION (Tencent), BSD 3-Clause: usr/lib/libncnn.so.1"
    echo "- GNU OpenMP runtime (libgomp), GPL v3 with the GCC Runtime Library Exception: usr/lib/libgomp.so.1"
    echo "- EdgePad 512x288 weights: Nightfall's fine-tune of ZipDepth (Fabio Tosi), MIT: usr/share/nightfall-meteor/models"
    echo "- NVIDIA TensorRT headers, Apache 2.0, compiled into Meteor's TensorRT shim"
    echo "- The Rust crates listed at the end"
    echo
    echo "Choosing Video Depth Anything in the tray downloads NVIDIA TensorRT from"
    echo "NVIDIA, under NVIDIA's licence: https://docs.nvidia.com/deeplearning/tensorrt/latest/reference/sla.html"
    echo "and the Video Depth Anything Small graphs, Apache 2.0. Neither ships in this file."
    echo
    echo "=========================================================================="
    echo "ncnn"
    cat "$WORK/stage/ncnn-LICENSE.txt"
    echo
    echo "=========================================================================="
    echo "ZipDepth"
    cat "$REPO/tools/ZipDepth/LICENSE"
    echo
    echo "=========================================================================="
    echo "NVIDIA TensorRT headers"
    cat third_party/tensorrt/LICENSE
    echo
    echo "=========================================================================="
    echo "GCC Runtime Library Exception (libgomp): https://www.gnu.org/licenses/gcc-exception-3.1.html"
    echo
    echo "=========================================================================="
    echo "Rust crates"
    cat "$WORK/stage/crates.txt"
} > "$APPDIR/usr/share/doc/nightfall-meteor/THIRD_PARTY_NOTICES.txt"

echo "== Packing"
TOOL="$OUT/appimagetool-x86_64.AppImage"
if [[ ! -x "$TOOL" ]]; then
    curl -fsSL -o "$TOOL" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod +x "$TOOL"
fi
TARGET="$OUT/Nightfall-Meteor-x86_64.AppImage"
rm -f "$TARGET" "$TARGET.zsync"
(cd "$OUT" && ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" --comp zstd \
    -u "gh-releases-zsync|tB0nE|nightfall|latest|Nightfall-Meteor-*x86_64.AppImage.zsync" \
    "$APPDIR" "$TARGET" >"$WORK/appimagetool.log" 2>&1) || { cat "$WORK/appimagetool.log" >&2; exit 1; }

BYTES=$(stat -c %s "$TARGET")
echo "$TARGET: $((BYTES / 1000000)) MB"
sha256sum "$TARGET"
if (( BYTES > MAX_BYTES )); then
    echo "Over the $((MAX_BYTES / 1000000)) MB limit" >&2
    exit 1
fi
