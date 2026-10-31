#!/bin/bash
set -euo pipefail
export DISPLAY=:1
export XDG_RUNTIME_DIR=/home/browser/.cache/nightfall-runtime
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
# Avoid dbus-launch helpers and per-client PulseAudio shared-memory pools.
export DBUS_SESSION_BUS_ADDRESS=unix:path=/tmp/nightfall-no-session-bus
mkdir -p /home/browser/.config/pulse
printf 'autospawn = no\nenable-shm = no\nenable-memfd = no\n' > /home/browser/.config/pulse/client.conf
chrome_flags=(--no-first-run --disable-gpu --disable-dev-shm-usage --enable-logging=stderr
  --user-data-dir=/home/browser/chrome-lab --window-size=1280,720 --window-position=0,0
  --hide-crash-restore-bubble --no-default-browser-check
  --renderer-process-limit=3 --disable-extensions
  --disable-component-extensions-with-background-pages --disable-background-networking
  )
if [[ "${1:-}" == --unsafe-no-sandbox ]]; then
  echo 'LAB ONLY: Chrome sandbox disabled. PRoot is not a security boundary.'
  chrome_flags+=(--no-sandbox)
fi
pids=()
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done; }
trap cleanup EXIT INT TERM
Xvfb :1 -screen 0 1280x720x24 -nolisten tcp -ac & pids+=($!)
for attempt in $(seq 1 50); do xdpyinfo -display :1 >/dev/null 2>&1 && break; sleep .1; done
xdpyinfo -display :1 >/dev/null
x11vnc -display :1 -rfbport 5902 -listen 127.0.0.1 -forever -shared -nopw -noxdamage -noshm & pids+=($!)
websockify --libserver --web=/usr/share/novnc 127.0.0.1:6082 127.0.0.1:5902 & pids+=($!)
pulseaudio -n --daemonize=no --disable-shm=true --exit-idle-time=-1 \
  --load=module-native-protocol-unix --load='module-null-sink sink_name=nightfall_lab rate=48000 channels=2 format=s16le' \
  --log-target=file:/home/browser/pulse.log & pids+=($!)
export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
# Neutral startup page. Account sign-in and playback are left to the user.
google-chrome-stable "${chrome_flags[@]}" http://127.0.0.1:6082/lab.html & pids+=($!)
wait "${pids[-1]}"
