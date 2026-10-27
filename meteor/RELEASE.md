# Nightfall Meteor: Linux release information

## Installation and host dependencies

Run the AppImage as your normal desktop user, with Sunshine or a compatible host
running. EdgePad 512 and 256 are included. Host inference uses Vulkan; install a
working NVIDIA, AMD or Intel Vulkan driver. Model compatibility is checked before
it is offered under a GPU. Inference performance depends on the GPU and model.

The AppImage baseline is Linux x86_64 with glibc 2.35 or newer and a compatible
libstdc++ (GLIBCXX_3.4.30). The host supplies the Vulkan loader, libudev, graphics
drivers and display/audio session services. VAAPI decoding additionally uses the
host libva/driver. Neither CUDA, NVIDIA encoder libraries nor AMD drivers are
copied from the build machine into the package.

PCVR requires Python 3 and either NVIDIA Vulkan/CUDA/NVENC or experimental AMD
Vulkan plus host libva/DRM/Mesa H.264/HEVC encoding and video processing. The AMD
path includes its private FFmpeg runtime and has passed packaged synthetic tests
on an RX480; real-game/headset and modern AMD validation remain outstanding.
Choose the tray's **PCVR encoder** for the next session. Auto prefers NVIDIA on
mixed systems and checks AMD capabilities otherwise. Foveated Encoding automatically greys out on unsupported encoders; live bitrate changes are rejected, so set the
bitrate before starting the session. It includes its own Monado and xrizer; installing WiVRN or SteamVR is
not required. Choose **Enable PCVR — install & restart Meteor**, then copy the
Steam launch options from the first tray item into each VR game's Properties →
General → Launch Options. Headset approval is saved per headset. XR audio
currently uses the retained Sunshine stream.

The Linux tray uses StatusNotifierItem (KDE, or GNOME with AppIndicator support).
Approval notifications use the desktop notification service. Copy uses KDE's
clipboard service, falling back to `wl-copy` or `xclip` on other desktops.
Without FUSE, the AppImage can be run with `APPIMAGE_EXTRACT_AND_RUN=1`.

## Optional VDA downloads

The GPU / model menu offers Vulkan VDA Small at 518×294 and 392×224. Each is
approximately 227 MB installed. The files come from the existing Nightfall VDA
model release and are verified against hashes compiled into Meteor. The download
can be cancelled/resumed. A model becomes available only after every file passes
verification. Downloading keeps the current model and GPU selection unchanged.

Vulkan VDA requires no TensorRT, CUDA or NVIDIA runtime download. The alternative
TensorRT path remains available on supported NVIDIA GPUs and retains its separate
NVIDIA license/download prompt. VDA Small weights are Apache 2.0; the license is
included with each download. These are conversions of the existing checkpoint,
not newly trained weights. The pinned download catalog is
`meteor/models/vda-vulkan-downloads.json` in the source companion.

## Source, licenses and build records

`THIRD_PARTY_NOTICES.txt` and adjacent files contain the Rust, ncnn, libopus,
FFmpeg, dav1d, ZipDepth and GNU OpenMP notices, including the GCC Runtime Library
Exception. The verified XR bundle retains Monado/cJSON/Eigen/codec-header
notices, xrizer's GPL license and dependency notices, its upstream revision and
Cargo.lock. `SOURCE_MANIFEST.json` records the Nightfall revision, whether local
changes were present and the exact selected source hashes.

Distribute the source companion created by `tools/build_release_sources.sh`
alongside a public XR AppImage. It contains the Nightfall build/runtime sources,
Monado's patched source, xrizer's pinned source, vendored Rust crates for both
programs, Eigen headers and the exact FFmpeg source archive. Model weights,
credentials, signing files, user configuration, logs and compiler output are not
included. The upstream component records are:

- Nightfall: https://github.com/tB0nE/nightfall, GPL v3.
- Monado: pinned in `tools/build_support/monado_xr_versions.sh`, with Nightfall's
  patches in `test/monado_*.patch`; source and license texts are included.
- xrizer: https://github.com/Supreeeme/xrizer, revision recorded in
  `xr-runtime/xrizer/UPSTREAM_REVISION`, GPL-3.0-or-later; source included.
- ncnn: https://github.com/Tencent/ncnn/tree/20260526, BSD 3-Clause.
- FFmpeg 8.0.1: https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz,
  LGPL-2.1-or-later, configured by `meteor/tools/build_ffmpeg_runtime.sh`.
- dav1d 0.9.2: https://code.videolan.org/videolan/dav1d/-/tree/0.9.2,
  BSD 2-Clause; distribution copyright included.
- GNU OpenMP runtime: exact Ubuntu package version recorded in
  `baseline-packages.txt`; distribution copyright and full exception included.
- ZipDepth: https://github.com/fabiotosi92/ZipDepth, MIT.
- Video Depth Anything Small: https://github.com/DepthAnything/Video-Depth-Anything,
  Apache 2.0; checkpoint SHA-256 recorded in each model manifest.

## Build commands

Use the pinned Ubuntu 22.04 build containers and Rust toolchain. The source
companion's `vendor` directories and `.cargo/vendor-config.toml` permit Cargo dependency
resolution offline, without overwriting the projects' original Cargo settings:

```sh
# In either Nightfall/meteor or upstream/xrizer from the source companion:
cargo --config .cargo/vendor-config.toml metadata --offline --locked --format-version 1
# For example, compile Meteor using those same offline dependencies:
cargo --config .cargo/vendor-config.toml build --offline --locked --release --no-default-features
```

Building the complete package still requires the documented
baseline OS/build tools and pinned ncnn/build inputs; the archive is source, not
an offline container image. The included Monado source already has Nightfall's
patches applied; do not apply them a second time when building that tree.

From a prepared Nightfall checkout, the supported packaging commands are:

```sh
bash tools/build_support/build_meteor_xrizer.sh
bash tools/build_support/build_meteor_xr_bundle.sh /new/runtime-package
NIGHTFALL_CONTAINER_ENGINE=docker METEOR_XR_BUNDLE=/new/runtime-package/bundle \
  bash meteor/tools/build_appimage.sh
bash meteor/tools/build_release_sources.sh /new/Nightfall-Meteor-sources.tar.gz
```

Keep the AppImage, source companion and their SHA-256 checksums together. There is
no need to redistribute downloaded NVIDIA TensorRT binaries in the AppImage.
