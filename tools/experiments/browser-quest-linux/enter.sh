#!/system/bin/sh
# Runs inside the Quest companion or ADB staging, using the existing Android kernel.
set -eu
BASE=${NF_LINUX_BASE:-/data/local/tmp/nightfall-browser-linux}
export LD_LIBRARY_PATH="$BASE/runtime/lib"
export PROOT_LOADER="$BASE/runtime/libexec/proot/loader"
export PROOT_LOADER_32="$BASE/runtime/libexec/proot/loader32"
export PROOT_TMP_DIR="$BASE/tmp"
mkdir -p "$BASE/tmp" "$BASE/shm"
IDENTITY=${NF_LINUX_ID:-0:0}
GUEST_HOME=/root
[ "$IDENTITY" = 0:0 ] || GUEST_HOME=/home/browser
exec "$BASE/runtime/bin/proot" --link2symlink --sysvipc -i "$IDENTITY" \
  -r "$BASE/rootfs" -b /dev -b /proc -b /sys -b "$BASE/shm:/dev/shm" -w / \
  /usr/bin/env -i HOME="$GUEST_HOME" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 TERM=xterm-256color "$@"
