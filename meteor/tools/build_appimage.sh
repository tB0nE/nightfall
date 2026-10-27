#!/usr/bin/env bash
# Builds Nightfall-Meteor-<version>-x86_64.AppImage: Meteor (without ONNX Runtime),
# ncnn and EdgePad 512/256 for Vulkan. VDA is a download from the
# tray (src/download.rs). See docs/plans/active/meteor-appimage.md.
#
# usage: tools/build_appimage.sh [models folder]
#
# The models folder must hold zipdepth_wide_512x288.ncnn.{param,bin}
# and zipdepth_edgepad_256.ncnn.{param,bin}
# (models/convert_ncnn.py); default ~/.local/share/nightfall-meteor/models.
# Needs podman (or docker) and network access. Output in target/appimage/.
set -euo pipefail

cd "$(dirname "$0")/.."
METEOR="$PWD"
REPO="$(cd .. && pwd)"
MODELS="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/nightfall-meteor/models}"
EDGEPAD=zipdepth_wide_512x288
EDGEPAD_SMALL=zipdepth_edgepad_256
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"

NCNN_VERSION=20260526
NCNN_ZIP="ncnn-$NCNN_VERSION-ubuntu-2204-shared"
NCNN_SHA256=69174c845eaf0e7b592f1e032b700d1b0ffda2915ebf69ee98b2d87411578d30
NCNN_LICENSE_SHA256=7c974bac98848df46be1af5bdaa3c3c9c01f6082a90f55caeb7f60c6208aa255
MAX_BYTES=$((100 * 1000 * 1000))
# appimagetool packs the AppImage, putting the AppImage runtime (the small
# launcher at the front of the file) in front of it. Both are pinned so a
# release build is reproducible; appimagetool would otherwise fetch the
# newest runtime.
APPIMAGETOOL_VERSION=1.9.1
APPIMAGETOOL_SHA256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
RUNTIME_VERSION=20251108
RUNTIME_SHA256=2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d

OUT="$METEOR/target/appimage"
WORK="$OUT/work"
APPDIR="$WORK/AppDir"
IMAGE=nightfall-meteor-appimage
ENGINE="${NIGHTFALL_CONTAINER_ENGINE:-$(command -v podman || command -v docker)}"
RUN_ARGS=(--rm --security-opt label=disable)
if [[ "$(basename "$ENGINE")" == podman ]]; then
    RUN_ARGS+=(--userns=keep-id)
else
    RUN_ARGS+=(--user "$(id -u):$(id -g)")
fi
XR_SUFFIX=""
if [[ -n "${METEOR_XR_BUNDLE:-}" ]]; then
    METEOR_XR_BUNDLE="$(cd "$METEOR_XR_BUNDLE" && pwd)"
    /usr/bin/python3 "$METEOR_XR_BUNDLE/tools/meteor_xr_runtime.py" --check
    /usr/bin/python3 "$REPO/tools/audit_meteor_xr_runtime.py" "$METEOR_XR_BUNDLE" --max-glibc 2.35 >/dev/null
    XR_SUFFIX="-XR-DEV"
fi

for f in "$MODELS/$EDGEPAD.ncnn.param" "$MODELS/$EDGEPAD.ncnn.bin" "$MODELS/$EDGEPAD_SMALL.ncnn.param" "$MODELS/$EDGEPAD_SMALL.ncnn.bin"; do
    [[ -f "$f" ]] || { echo "Missing $f (see models/README.md)" >&2; exit 1; }
done
grep -q "^Input .* 0=512 1=288 2=3" "$MODELS/$EDGEPAD.ncnn.param" \
    || { echo "$EDGEPAD.ncnn.param has no input size; convert it with models/convert_ncnn.py" >&2; exit 1; }
grep -q "^Input .* 0=256 1=256 2=3" "$MODELS/$EDGEPAD_SMALL.ncnn.param" \
    || { echo "$EDGEPAD_SMALL.ncnn.param has no 256x256 input size" >&2; exit 1; }

mkdir -p "$OUT/cargo-target" "$OUT/cargo-registry" "$WORK"
rm -rf "${APPDIR:?}" "${WORK:?}/stage"
mkdir -p "$WORK/stage"

echo "== Building Meteor in Ubuntu 22.04"
"$ENGINE" build -q -t "$IMAGE" -f tools/appimage/Containerfile tools/appimage >/dev/null
"$ENGINE" run "${RUN_ARGS[@]}" \
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
bash tools/build_ffmpeg_runtime.sh /target/ffmpeg-runtime /target/ffmpeg-build
cp -L /target/ffmpeg-runtime/lib/libavcodec.so.62 /target/ffmpeg-runtime/lib/libavutil.so.60 /target/ffmpeg-runtime/lib/libswscale.so.9 /stage/
cp -L /target/ffmpeg-runtime/lib/libdav1d.so.* /stage/
cp /target/ffmpeg-runtime/FFmpeg-COPYING.LGPLv2.1 /target/ffmpeg-runtime/dav1d-copyright /stage/
cargo about generate --no-default-features --fail -c tools/appimage/about.toml tools/appimage/about.hbs > /stage/crates.txt

cd /tmp
curl -fsSL -o ncnn.zip "https://github.com/Tencent/ncnn/releases/download/$NCNN_VERSION/$NCNN_ZIP.zip"
echo "$NCNN_SHA256  ncnn.zip" | sha256sum -c --quiet
curl -fsSL -o ncnn-LICENSE.txt "https://raw.githubusercontent.com/Tencent/ncnn/$NCNN_VERSION/LICENSE.txt"
echo "$NCNN_LICENSE_SHA256  ncnn-LICENSE.txt" | sha256sum -c --quiet
unzip -q ncnn.zip
cp "$NCNN_ZIP/lib/libncnn.so.1."* /stage/libncnn.so.1
c++ -O2 -std=c++17 -shared -fPIC /src/native/vda_vulkan.cpp \
    -I"$NCNN_ZIP/include/ncnn" -L"$NCNN_ZIP/lib" -lncnn \
    -o /stage/libmeteor_vda_vulkan.so
patchelf --set-rpath "\$ORIGIN" /stage/libmeteor_vda_vulkan.so
cp ncnn-LICENSE.txt /stage/
# ncnn needs libgomp, which not every distribution installs; it finds the
# copy next to it.
cp /usr/lib/x86_64-linux-gnu/libgomp.so.1 /stage/
cp /usr/share/doc/libgomp1/copyright /stage/libgomp-copyright.txt
cp /usr/share/common-licenses/GPL-3 /stage/GPL-3.txt
dpkg-query -W libgomp1 libdav1d-dev > /stage/baseline-packages.txt
patchelf --set-rpath "\$ORIGIN" /stage/libncnn.so.1
echo "glibc needed: $(objdump -T /stage/nightfall-meteor /stage/libncnn.so.1 /stage/libgomp.so.1 | grep -o "GLIBC_[0-9.]*" | sort -uV | tail -1)"
'

echo "== Assembling the AppDir"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/nightfall-meteor/models" \
    "$APPDIR/usr/share/applications" "$APPDIR/usr/share/icons/hicolor/732x732/apps" "$APPDIR/usr/share/doc/nightfall-meteor"
install -m755 "$WORK/stage/nightfall-meteor" "$APPDIR/usr/bin/"
install -m644 "$WORK/stage/libncnn.so.1" "$WORK/stage/libgomp.so.1" "$APPDIR/usr/lib/"
install -m644 "$WORK/stage/libmeteor_vda_vulkan.so" "$APPDIR/usr/lib/"
install -m644 "$WORK/stage/libavcodec.so.62" "$WORK/stage/libavutil.so.60" "$WORK/stage/libswscale.so.9" "$WORK"/stage/libdav1d.so.* "$APPDIR/usr/lib/"
install -m644 "$MODELS/$EDGEPAD.ncnn.param" "$MODELS/$EDGEPAD.ncnn.bin" "$APPDIR/usr/share/nightfall-meteor/models/"
install -m644 "$MODELS/$EDGEPAD_SMALL.ncnn.param" "$MODELS/$EDGEPAD_SMALL.ncnn.bin" "$APPDIR/usr/share/nightfall-meteor/models/"
# Keep optional VDA weights out of default packages even on a developer machine
# that has them installed. They remain available from the user model directory.
if [[ "${METEOR_BUNDLE_VDA_VULKAN:-0}" == 1 ]]; then
    for variant in vda_vulkan_518x294 vda_vulkan_392x224; do
        [[ -f "$MODELS/$variant/manifest.json" ]] || { echo "Missing requested VDA export: $variant" >&2; exit 1; }
        cp -a "$MODELS/$variant" "$APPDIR/usr/share/nightfall-meteor/models/"
    done
fi
# Optional managed XR bundle. It is copied out to writable per-user storage by
# --install-xr-runtime; never run session state directly from the AppImage mount.
if [[ -n "${METEOR_XR_BUNDLE:-}" ]]; then
    /usr/bin/python3 "$METEOR_XR_BUNDLE/tools/meteor_xr_runtime.py" --check
    /usr/bin/python3 "$REPO/tools/audit_meteor_xr_runtime.py" "$METEOR_XR_BUNDLE" \
        --max-glibc 2.35 --output "$WORK/xr-runtime-audit.json"
    /usr/bin/python3 "$METEOR_XR_BUNDLE/tools/meteor_xr_install.py" "$METEOR_XR_BUNDLE" \
        --export "$APPDIR/usr/share/nightfall-meteor/xr-bundle"
fi
install -m755 tools/appimage/AppRun "$APPDIR/AppRun"
install -m644 tools/appimage/nightfall-meteor.desktop "$APPDIR/"
install -m644 tools/appimage/nightfall-meteor.desktop "$APPDIR/usr/share/applications/"
install -m644 "$REPO/src/assets/nightfall_icon_v1.png" "$APPDIR/nightfall-meteor.png"
install -m644 "$REPO/src/assets/nightfall_icon_v1.png" "$APPDIR/usr/share/icons/hicolor/732x732/apps/nightfall-meteor.png"
install -m644 "$REPO/LICENSE" "$APPDIR/usr/share/doc/nightfall-meteor/LICENSE"
install -m644 "$METEOR/RELEASE.md" "$APPDIR/usr/share/doc/nightfall-meteor/RELEASE.md"
install -m644 "$WORK/stage/libgomp-copyright.txt" "$WORK/stage/GPL-3.txt" "$WORK/stage/baseline-packages.txt" "$APPDIR/usr/share/doc/nightfall-meteor/"
/usr/bin/python3 "$METEOR/tools/release_metadata.py" --metadata "$APPDIR/usr/share/doc/nightfall-meteor/SOURCE_MANIFEST.json"
{
    echo "Nightfall Meteor $VERSION is free software under the GNU GPL v3 (LICENSE)."
    echo "It includes the components below, under their own licences."
    echo
    echo "- ncnn $NCNN_VERSION (Tencent), BSD 3-Clause: usr/lib/libncnn.so.1"
    echo "- GNU OpenMP runtime (libgomp), GPL v3 with the GCC Runtime Library Exception: usr/lib/libgomp.so.1"
    echo "- EdgePad 512x288 and 256x256 weights: Nightfall's ZipDepth models (Fabio Tosi), MIT: usr/share/nightfall-meteor/models"
    echo "- NVIDIA TensorRT headers, Apache 2.0, compiled into Meteor's TensorRT shim"
    echo "- libopus (Xiph.Org Foundation and others), BSD 3-Clause, compiled into Meteor (microphone)"
    echo "- FFmpeg 8.0.1, LGPL 2.1 or later: VAAPI/software decoding and HEVC VAAPI encoder runtime"
    echo "  Unmodified source: https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz"
    echo "- dav1d, BSD 2-Clause: AV1 software decoding"
    if [[ -n "${METEOR_XR_BUNDLE:-}" ]]; then
        echo "- Managed Monado XR runtime, xrizer (GPL-3.0-or-later), bridges and private cJSON: usr/share/nightfall-meteor/xr-bundle"
        echo "  Upstream and dependency notices are retained inside that verified bundle."
    fi
    echo "- The Rust crates listed at the end"
    echo
    echo "Choosing NVIDIA TensorRT Video Depth Anything in the tray downloads TensorRT from"
    echo "NVIDIA, under NVIDIA's licence: https://docs.nvidia.com/deeplearning/tensorrt/latest/reference/sla.html"
    echo "TensorRT graphs are downloaded separately. Optional Vulkan VDA graphs, Apache 2.0, carry their LICENSE in each model directory."
    echo "Vulkan VDA does not download or require TensorRT."
    echo "Exact Nightfall source hashes and build instructions: SOURCE_MANIFEST.json and RELEASE.md."
    echo "Distribute the generated source companion archive with public binary releases."
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
    echo "libopus"
    cat "$OUT"/cargo-registry/src/*/audiopus_sys-*/opus/COPYING
    echo
    echo "=========================================================================="
    echo "FFmpeg"
    cat "$WORK/stage/FFmpeg-COPYING.LGPLv2.1"
    echo
    echo "=========================================================================="
    echo "dav1d"
    cat "$WORK/stage/dav1d-copyright"
    echo
    echo "=========================================================================="
    echo "GNU OpenMP runtime: full distribution copyright and GCC Runtime Library Exception"
    cat "$WORK/stage/libgomp-copyright.txt"
    echo
    echo "=========================================================================="
    echo "Rust crates"
    cat "$WORK/stage/crates.txt"
} > "$APPDIR/usr/share/doc/nightfall-meteor/THIRD_PARTY_NOTICES.txt"

echo "== Packing"
TOOL="$OUT/appimagetool-$APPIMAGETOOL_VERSION-x86_64.AppImage"
RUNTIME="$OUT/runtime-$RUNTIME_VERSION-x86_64"
if [[ ! -x "$TOOL" ]]; then
    curl -fsSL -o "$TOOL" "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_VERSION/appimagetool-x86_64.AppImage"
    chmod +x "$TOOL"
fi
[[ -f "$RUNTIME" ]] || curl -fsSL -o "$RUNTIME" "https://github.com/AppImage/type2-runtime/releases/download/$RUNTIME_VERSION/runtime-x86_64"
echo "$APPIMAGETOOL_SHA256  $TOOL" | sha256sum -c --quiet
echo "$RUNTIME_SHA256  $RUNTIME" | sha256sum -c --quiet
# The version is in the name from the start: the .zsync file records the
# AppImage's file name, so the release asset must keep the name built here.
TARGET="$OUT/Nightfall-Meteor-$VERSION$XR_SUFFIX-x86_64.AppImage"
rm -f "$TARGET" "$TARGET.zsync"
(cd "$OUT" && ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" --comp zstd --runtime-file "$RUNTIME" \
    -u "gh-releases-zsync|tB0nE|nightfall|latest|Nightfall-Meteor-*x86_64.AppImage.zsync" \
    "$APPDIR" "$TARGET" >"$WORK/appimagetool.log" 2>&1) || { cat "$WORK/appimagetool.log" >&2; exit 1; }

BYTES=$(stat -c %s "$TARGET")
echo "$TARGET: $((BYTES / 1000000)) MB"
sha256sum "$TARGET"
if (( BYTES > MAX_BYTES )); then
    echo "Over the $((MAX_BYTES / 1000000)) MB limit" >&2
    exit 1
fi
