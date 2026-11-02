#!/bin/bash
set -euo pipefail
export DISPLAY=:1
# Use the proven 720p baseline; retain an opt-in 1080p comparison without an APK rebuild.
display_size=1280x720
if [[ -f /tmp/nightfall-display-size ]]; then read -r display_size < /tmp/nightfall-display-size; fi
case "$display_size" in 1280x720|1920x1080) ;; *) echo 'Unsupported lab display size' >&2; exit 1 ;; esac
export XDG_RUNTIME_DIR=/home/browser/.cache/nightfall-runtime
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
# Avoid dbus-launch helpers and per-client PulseAudio shared-memory pools.
export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/nightfall-no-session-bus
mkdir -p /home/browser/.config/pulse
printf 'autospawn = no\nenable-shm = no\nenable-memfd = no\n' > /home/browser/.config/pulse/client.conf
chrome_flags=(--no-first-run --disable-dev-shm-usage --enable-logging=stderr
  --user-data-dir=/home/browser/chrome-lab "--window-size=${display_size/x/,}" --window-position=0,0
  --hide-crash-restore-bubble --no-default-browser-check
  --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222
  --kiosk --test-type=nightfall-lab
  --renderer-process-limit=3 --disable-extensions
  --disable-component-extensions-with-background-pages --disable-background-networking
  )
# Explicit experiment opt-in. Keep the known software path as the default.
chrome_renderer=software
if [[ -f /tmp/nightfall-chrome-renderer ]]; then read -r chrome_renderer < /tmp/nightfall-chrome-renderer; fi
# Service-owned GPU selection is authoritative. A stale manual experiment
# file must not reactivate Linux GPU rendering after the failure guard turns
# it off. An unset variable retains explicit shell-lab overrides.
case "${NF_GPU_DIRECT:-}" in
  1) chrome_renderer=gpu-direct ;;
  0) chrome_renderer=software ;;
  '') ;;
  *) echo 'Unsupported service GPU selection' >&2; exit 1 ;;
esac
chrome_environment=()
chrome_launch=(env)
xserver=(Xvfb)
case "$chrome_renderer" in
  software) chrome_flags+=(--disable-gpu) ;;
  gpu)
    mesa_dir=/opt/mesa-freedreno/lib/aarch64-linux-gnu
    shim=/opt/nightfall-kgsl/libnightfall-kgsl-compat.so
    if [[ ! -f "$shim" || ! -f "$mesa_dir/libEGL.so.1" ]]; then
      echo 'GPU lab mode requires the isolated Mesa bundle and corrected KGSL adapter' >&2
      exit 1
    fi
    chrome_flags+=(--ozone-platform=x11 --use-gl=angle --use-angle=gl-egl --enable-gpu)
    # Only Chrome inherits the driver override. Xvfb, audio and input stay as-is.
    chrome_environment=("LD_PRELOAD=$shim" "LD_LIBRARY_PATH=$mesa_dir"
      "LIBGL_DRIVERS_PATH=$mesa_dir/dri" "GALLIUM_DRIVER=kgsl"
      "MESA_LOADER_DRIVER_OVERRIDE=kgsl" "EGL_PLATFORM=surfaceless")
    ;;
  gpu-direct)
    mesa_dir=/opt/mesa-va-pps/usr/lib/aarch64-linux-gnu
    compat=/tmp/libnightfall-kgsl-compat.so
    drm=/opt/mesa-va/usr/lib/aarch64-linux-gnu/libtva_drm_shim_wayland.so
    [[ -f "$mesa_dir/libEGL_mesa.so.0" && -f "$compat" && -f "$drm" && -x /opt/nightfall-xvfb/Xvfb ]] || {
      echo 'GPU direct mode requires the matched Mesa/VA/X11 experiment artifacts' >&2; exit 1;
    }
    export LD_PRELOAD="$compat:$drm"
    export LD_LIBRARY_PATH="$mesa_dir:/usr/lib/aarch64-linux-gnu:/opt/mesa-va/usr/lib/aarch64-linux-gnu"
    export LIBGL_DRIVERS_PATH="$mesa_dir/dri" GBM_BACKENDS_PATH="$mesa_dir/gbm" LIBVA_DRIVERS_PATH="$mesa_dir/dri"
    export LIBVA_DRIVER_NAME=termuxva TERMUX_VA_BRIDGE=1 TERMUX_VA_GPU_BACKEND=kgsl TERMUX_VA_X11_DRI3=1
    export TERMUX_VA_SOCKET=/tmp/nightfall-va/browser.sock
    export GALLIUM_DRIVER=kgsl MESA_LOADER_DRIVER_OVERRIDE=kgsl EGL_PLATFORM=surfaceless NF_XVFB_READBACK_MS=0
    source /tmp/gpu-process-groups.sh
    # Diagnostic only: apply the same Mesa render policy to the server and
    # Chrome GPU subprocesses. Never inherited by Android's system driver.
    driver_policy=default
    if [[ -f /tmp/nf-gpu-driver-policy ]]; then read -r driver_policy < /tmp/nf-gpu-driver-policy || true; fi
    case "$driver_policy" in
      default) ;;
      sysmem) export FD_MESA_DEBUG=sysmem ;;
      linear) export FD_MESA_DEBUG=notile,noubwc ;;
      *) echo 'Invalid GPU driver diagnostic policy' >&2; exit 1 ;;
    esac
    chrome_launch=(setsid env -u EGL_PLATFORM)
    xserver=(setsid /opt/nightfall-xvfb/Xvfb)
    chrome_flags+=(--ozone-platform=x11 --use-gl=angle --use-angle=gles-egl --enable-gpu
      --hardware-video-device-path=/dev/kgsl-3d0 --render-node-override=/dev/kgsl-3d0
      --ignore-gpu-blocklist --enable-native-gpu-memory-buffers --enable-gpu-compositing
      --disable-zero-copy --disable-gpu-rasterization
      --enable-features=AcceleratedVideoDecoder,VaapiVideoDecoder,VaapiVideoDecodeLinux,AcceleratedVideoDecodeLinuxGL,VaapiIgnoreDriverChecks
      --disable-features=AcceleratedVideoDecodeLinuxZeroCopyGL,VaapiVideoMinResolutionForPerformance,PreferMappableSharedImage)
    ;;
  *) echo 'Unsupported lab Chrome renderer' >&2; exit 1 ;;
esac
if [[ "${1:-}" == --unsafe-no-sandbox ]]; then
  echo 'LAB ONLY: Chrome sandbox disabled. PRoot is not a security boundary.'
  chrome_flags+=(--no-sandbox)
fi
pids=()
profile_cleanup=
initial_url=http://127.0.0.1:6082/lab.html?nightfall-compat=1
if [[ ${2:-} == --generated-gpu-test ]]; then
  profile_cleanup=$(mktemp -d /tmp/nf-live-gpu-XXXXXX)
  test_flags=()
  for flag in "${chrome_flags[@]}"; do [[ $flag == --user-data-dir=* ]] || test_flags+=("$flag"); done
  chrome_flags=("${test_flags[@]}" --user-data-dir="$profile_cleanup")
  initial_url=file:///tmp/gpu-runtime-test.html
fi
cleanup() { trap - EXIT; trap '' INT TERM; if declare -F nf_gpu_stop_groups >/dev/null; then nf_gpu_stop_groups; fi; for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; rm -f /tmp/nightfall-chrome.pid; [[ -z "$profile_cleanup" ]] || rm -rf -- "$profile_cleanup"; }
trap cleanup EXIT INT TERM
mkdir -p /tmp/nightfall-framebuffer
# Allocate a new inode on restart; an old mapped reader must never see truncation.
rm -f /tmp/nightfall-framebuffer/Xvfb_screen0
extra_xserver=()
if [[ $chrome_renderer == gpu-direct ]]; then extra_xserver=(-noreset -vfbdevice /dev/kgsl-3d0); fi
rm -f /tmp/nightfall-chrome.pid
"${xserver[@]}" :1 -screen 0 "${display_size}x24" -fbdir /tmp/nightfall-framebuffer -nolisten tcp -ac -nocursor "${extra_xserver[@]}" & pids+=($!)
if [[ $chrome_renderer == gpu-direct ]]; then nf_gpu_register_group "${pids[-1]}"; fi
for attempt in $(seq 1 50); do xdpyinfo -display :1 >/dev/null 2>&1 && break; sleep .1; done
xdpyinfo -display :1 >/dev/null
x11vnc -display :1 -rfbport 5902 -listen 127.0.0.1 -forever -shared -nopw -noxdamage -noshm & pids+=($!)
# Direct display already reads Xvfb's mmap. Keep its input off the framebuffer
# polling loop (which can delay hover events by hundreds of milliseconds).
# Retain 5902 unchanged for the noVNC fallback and desk-side inspection.
x11vnc -display :1 -rfbport 5903 -listen 127.0.0.1 -forever -shared -nopw \
  -nofb -nonap -sb 0 -wait 5 -nosel -nobell & pids+=($!)
websockify --libserver --web=/usr/share/novnc 127.0.0.1:6082 127.0.0.1:5902 & pids+=($!)
if [[ -f /tmp/frame-metrics.py ]]; then
  python3 /tmp/frame-metrics.py & pids+=($!)
fi
pulseaudio -n --daemonize=no --disable-shm=true --exit-idle-time=-1 \
  --load=module-native-protocol-unix --load='module-null-sink sink_name=nightfall_lab rate=48000 channels=2 format=s16le' \
  --log-target=file:/home/browser/pulse.log & pids+=($!)
export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
# Neutral startup page. Account sign-in and playback are left to the user.
"${chrome_launch[@]}" "${chrome_environment[@]}" google-chrome-stable "${chrome_flags[@]}" --app="$initial_url" & pids+=($!)
printf '%s\n' "${pids[-1]}" > /tmp/nightfall-chrome.pid
if [[ $chrome_renderer == gpu-direct ]]; then nf_gpu_register_group "${pids[-1]}"; fi
wait "${pids[-1]}"
