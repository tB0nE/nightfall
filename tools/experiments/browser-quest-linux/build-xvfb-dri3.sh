#!/usr/bin/env bash
# Cross-build the separately staged Xvfb experiment; no install or playback.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
experiment_dir="$repo_root/tools/experiments/browser-quest-linux"
source_dir="$repo_root/.build-cache/browser-quest-linux/xorg-server-21.1.19"
[[ -f "$source_dir/hw/vfb/InitOutput.c" ]] || { echo 'Prepare checksum-verified patched source as described in the plan.' >&2; exit 1; }
gles_patch="$experiment_dir/xvfb-gles-context.patch"
if patch --silent --dry-run -d "$source_dir" -p1 < "$gles_patch"; then
  patch --silent -d "$source_dir" -p1 < "$gles_patch"
else
  patch --silent --dry-run --reverse -d "$source_dir" -p1 < "$gles_patch"
fi
diagnostics_patch="$experiment_dir/xvfb-gles-context-diagnostics.patch"
if patch --silent --dry-run -d "$source_dir" -p1 < "$diagnostics_patch"; then
  patch --silent -d "$source_dir" -p1 < "$diagnostics_patch"
else
  patch --silent --dry-run --reverse -d "$source_dir" -p1 < "$diagnostics_patch"
fi
cp "$experiment_dir/glamor-async-capture.c" "$source_dir/glamor/"
podman build -t localhost/nightfall-xvfb-dri3-builder -f "$experiment_dir/XvfbDri3.Containerfile" "$experiment_dir"
podman run --rm --network=none -v "$source_dir:/src:Z" -v "$experiment_dir:/nf:ro,Z" -w /src \
  localhost/nightfall-xvfb-dri3-builder sh -c 'meson setup build-nightfall --cross-file /nf/mesa-va-cross.ini \
    --prefix=/usr -Dbuildtype=release -Dxorg=false -Dxephyr=false -Dxnest=false -Dxwin=false \
    -Dxquartz=false -Dxvfb=true -Dglamor=true -Ddri3=true -Dglx=true -Dudev=false -Dudev_kms=false \
    -Dsystemd_logind=false -Dlibunwind=false -Ddocs=false -Ddevel-docs=false -Dsecure-rpc=false \
    -Dsha1=libcrypto && ninja -C build-nightfall -j 12 hw/vfb/Xvfb'
echo "$source_dir/build-nightfall/hw/vfb/Xvfb"
