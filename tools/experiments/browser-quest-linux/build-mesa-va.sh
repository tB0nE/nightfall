#!/usr/bin/env bash
# Reproducible isolated experiment; never installs a system/headset driver.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"
experiment_dir="$repo_root/tools/experiments/browser-quest-linux"
source_dir="$repo_root/.build-cache/browser-quest-linux/mesa-va-source"
revision=eb3e7fd4f009cab04b1482aad4843c0bde28a786
if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$source_dir"
  git -C "$source_dir" init
  git -C "$source_dir" remote add origin https://github.com/lfdevs/mesa-for-android-container.git
  git -C "$source_dir" fetch --depth 1 origin "$revision"
  git -C "$source_dir" checkout --detach FETCH_HEAD
fi
[[ "$(git -C "$source_dir" rev-parse HEAD)" == "$revision" ]] || { echo 'Unexpected Mesa revision; preserve checkout and inspect it.' >&2; exit 1; }
patch_file="$experiment_dir/mesa-h264-pps-defaults.patch"
if git -C "$source_dir" apply --check "$patch_file" 2>/dev/null; then
  git -C "$source_dir" apply "$patch_file"
else
  git -C "$source_dir" apply --reverse --check "$patch_file"
fi
# The upstream Android compositor uses a private modifier sentinel; native
# X11 needs DRM_FORMAT_MOD_LINEAR (zero) transmitted without rewriting it.
linear_patch="$experiment_dir/mesa-native-x11-linear-modifier.patch"
if git -C "$source_dir" apply --check "$linear_patch" 2>/dev/null; then
  git -C "$source_dir" apply "$linear_patch"
else
  git -C "$source_dir" apply --reverse --check "$linear_patch"
fi
coherent_patch="$experiment_dir/mesa-kgsl-coherent-readback.patch"
if git -C "$source_dir" apply --check "$coherent_patch" 2>/dev/null; then
  git -C "$source_dir" apply "$coherent_patch"
else
  git -C "$source_dir" apply --reverse --check "$coherent_patch"
fi
cp "$experiment_dir/h264-reference-defaults.h" "$source_dir/src/gallium/frontends/va/"
podman build -t localhost/nightfall-mesa-va-builder -f "$experiment_dir/MesaVa.Containerfile" "$experiment_dir"
container_args=(--rm --network=none -v "$source_dir:/src:Z" -v "$experiment_dir:/nf:ro,Z" -w /src localhost/nightfall-mesa-va-builder)
podman run "${container_args[@]}" meson setup build-nightfall --cross-file /nf/mesa-va-cross.ini --prefix=/usr --libdir=lib/aarch64-linux-gnu \
  -Dplatforms=x11 -Dgallium-drivers=freedreno -Dgallium-va=enabled -Dtermux-va-bridge=enabled \
  -Dtermux-va-wayland-shim=disabled -Dvideo-codecs=all -Dvulkan-drivers= -Dllvm=disabled \
  -Dglx=dri -Degl=enabled -Dgles2=enabled -Dgles1=disabled -Dglvnd=enabled \
  -Dlibunwind=disabled -Dfreedreno-kmds=kgsl -Dbuildtype=release -Dbuild-tests=false
podman run "${container_args[@]}" ninja -C build-nightfall -j "${NF_MESA_BUILD_JOBS:-12}"
echo "$source_dir/build-nightfall/src/gallium/targets/dri/libgallium-27.0.0-devel.so"
