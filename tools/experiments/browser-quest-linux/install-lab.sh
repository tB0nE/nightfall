#!/usr/bin/env bash
# Deploy the companion app without changing Nightfall or copying VM browser data.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
TOOLS="$ROOT/tools/experiments/browser-quest-linux"
WORK="$ROOT/.build-cache/browser-quest-linux"
ADB=${ADB:-adb}
BASE=/data/local/tmp/nightfall-browser-linux
bash "$TOOLS/build-lab.sh"
"$ADB" install -r "$WORK/lab-build/Nightfall-Browser-Lab.apk"
"$ADB" shell "test -x $BASE/rootfs/opt/google/chrome/chrome"
"$ADB" push "$TOOLS/enter.sh" "$BASE/enter.sh"
# Preserve the companion app's existing browser profile on repeated deployments.
"$ADB" shell "set -o pipefail; tar --exclude=rootfs/home --exclude=rootfs/root --exclude=rootfs/tmp -C $BASE -cf - rootfs runtime enter.sh | run-as app.nightfall.browserlab sh -c 'mkdir -p files/linux; cd files/linux; tar -xf -'"
"$ADB" shell "run-as app.nightfall.browserlab mkdir -p files/linux/rootfs/tmp files/linux/rootfs/home/browser"
"$ADB" shell -T "run-as app.nightfall.browserlab sh -c 'cat > files/linux/rootfs/tmp/start-desktop.sh'" < "$TOOLS/start-desktop.sh"
"$ADB" shell -T "run-as app.nightfall.browserlab sh -c 'cat > files/linux/rootfs/usr/share/novnc/lab.html'" < "$TOOLS/lab.html"
"$ADB" shell -T "run-as app.nightfall.browserlab sh -c 'cat > files/linux/rootfs/tmp/frame-metrics.py'" < "$TOOLS/frame-metrics.py"
"$ADB" shell -T "run-as app.nightfall.browserlab sh -c 'cat > files/linux/rootfs/usr/share/novnc/performance-viewer.html'" < "$TOOLS/performance-viewer.html"
"$ADB" shell -T "run-as app.nightfall.browserlab sh -c 'cat > files/linux/rootfs/usr/share/novnc/color-probe.html'" < "$TOOLS/color-probe.html"
"$ADB" shell -T "run-as app.nightfall.browserlab sh -c 'cat > files/linux/rootfs/usr/share/novnc/input-probe.html'" < "$TOOLS/input-probe.html"
if [[ -f "$WORK/stability.mp4" ]]; then
  "$ADB" shell -T "run-as app.nightfall.browserlab sh -c 'cat > files/linux/rootfs/usr/share/novnc/stability.html'" < "$TOOLS/stability.html"
  "$ADB" shell -T "run-as app.nightfall.browserlab sh -c 'cat > files/linux/rootfs/usr/share/novnc/stability.mp4'" < "$WORK/stability.mp4"
fi
if [[ -f "$WORK/stability-60.mp4" ]]; then
  "$ADB" shell -T "run-as app.nightfall.browserlab sh -c 'cat > files/linux/rootfs/usr/share/novnc/stability-60.mp4'" < "$WORK/stability-60.mp4"
fi
"$ADB" shell -T "run-as app.nightfall.browserlab sh -c 'cat > files/linux/rootfs/tmp/forward-audio.sh'" < "$TOOLS/forward-audio.sh"
echo 'Installed Nightfall Linux Browser Lab. Open it from Unknown Sources.'
echo 'To view the Quest browser on this PC: adb forward tcp:6082 tcp:6082'
