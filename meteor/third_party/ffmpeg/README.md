# FFmpeg API headers

FFmpeg 8 public headers (libavcodec 62, libavutil 60, libswscale 9), copied from
the local Vibepollo FFmpeg dependency. Original copyright and license notices
are retained in each header; see COPYING.LGPLv2.1. Upstream: https://ffmpeg.org/.

These headers compile the dynamically loaded decoder shim. No FFmpeg binary is
linked into Meteor by this directory. The shim verifies runtime ABI majors
before accessing public structures. Runtime libraries are optional on NVIDIA;
the Linux AppImage packaging script provides a minimal compatible build.
