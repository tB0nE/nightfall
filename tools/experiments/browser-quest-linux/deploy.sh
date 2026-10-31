#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TOOLS="$ROOT/tools/experiments/browser-quest-linux"
WORK="$ROOT/.build-cache/browser-quest-linux"
ADB=${ADB:-adb}
BASE=/data/local/tmp/nightfall-browser-linux
/usr/bin/python3 "$TOOLS/prepare.py"
"$ADB" get-state >/dev/null
"$ADB" shell "mkdir -p $BASE/runtime $BASE/tmp $BASE/rootfs"
"$ADB" push "$WORK/runtime/." "$BASE/runtime/"
if ! "$ADB" shell "test -x $BASE/rootfs/bin/bash"; then
  "$ADB" push "$WORK/rootfs-portable.tar.gz" "$BASE/"
  "$ADB" shell "cd $BASE/rootfs && tar -xzf ../rootfs-portable.tar.gz"
fi
"$ADB" shell "mkdir -p $BASE/rootfs/tmp $BASE/rootfs/dev $BASE/rootfs/proc $BASE/rootfs/sys $BASE/rootfs/run; chmod 1777 $BASE/rootfs/tmp; rm -f $BASE/rootfs/etc/resolv.conf; echo nameserver 1.1.1.1 > $BASE/rootfs/etc/resolv.conf"
"$ADB" push "$TOOLS/enter.sh" "$BASE/enter.sh"
"$ADB" push "$TOOLS/install-browser.sh" "$BASE/rootfs/tmp/install-browser.sh"
"$ADB" push "$WORK/google-chrome-arm64.deb" "$BASE/rootfs/tmp/"
"$ADB" shell "sh $BASE/enter.sh /bin/bash /tmp/install-browser.sh"
