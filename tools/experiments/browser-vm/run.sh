#!/usr/bin/env bash
# Desktop x86/KVM or ARM64/TCG baseline. No host GPU reconfiguration.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ARCH="${BROWSER_VM_ARCH:-amd64}"
case "$ARCH" in amd64|arm64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;; esac
WORK="$ROOT/.build-cache/browser-drm-vm"
WEB_PORT=6080
SSH_PORT=2223
VCPUS=4
if [[ "$ARCH" == arm64 ]]; then WORK="$ROOT/.build-cache/browser-drm-vm-arm64"; WEB_PORT=6081; SSH_PORT=2224; VCPUS=1; fi
TOOLS="$ROOT/tools/experiments/browser-vm"
IMAGE=nightfall-browser-vm-tools:ubuntu24.04
NAME=nightfall-browser-vm
if [[ "$ARCH" == arm64 ]]; then NAME=nightfall-browser-vm-arm64; fi
case "${1:-start}" in
 stop) docker stop "$NAME"; exit ;;
 status) docker ps -a --filter "name=^/${NAME}$"; exit ;;
 logs) docker logs --tail 80 "$NAME"; exit ;;
 start) ;;
 *) echo 'Usage: run.sh [start|stop|status|logs]' >&2; exit 2 ;;
esac
mkdir -p "$WORK"
[[ "$ARCH" == arm64 ]] || test -c /dev/kvm || { echo 'This desktop baseline needs /dev/kvm.' >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -t "$IMAGE" "$TOOLS"
if [[ ! -f "$WORK/noble-server-cloudimg-${ARCH}.img" ]]; then
 curl -fL --retry 3 -o "$WORK/noble-server-cloudimg-${ARCH}.img" https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-${ARCH}.img
 curl -fL --retry 3 -o "$WORK/SHA256SUMS" https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
fi
(cd "$WORK" && awk -v name="noble-server-cloudimg-${ARCH}.img" '$2 == name || $2 == "*" name {print}' SHA256SUMS | sha256sum --check --status)
[[ -f "$WORK/ssh-key" ]] || ssh-keygen -q -t ed25519 -N '' -f "$WORK/ssh-key" -C nightfall-browser-vm
/usr/bin/python3 - "$TOOLS/cloud-init.yaml" "$WORK" "$ARCH" <<'PY'
from pathlib import Path
import sys
source,work=Path(sys.argv[1]),Path(sys.argv[2])
(work/'user-data').write_text(source.read_text().replace('__SSH_PUBLIC_KEY__',(work/'ssh-key.pub').read_text().strip()).replace('current_amd64.deb', 'current_'+sys.argv[3]+'.deb'))
(work/'meta-data').write_text('instance-id: nightfall-browser-vm-v1\nlocal-hostname: nightfall-browser-vm\n')
PY
if docker ps --format '{{.Names}}' | grep -Fxq "$NAME"; then
 echo "Already running: http://127.0.0.1:$WEB_PORT/vnc.html?autoconnect=true&resize=scale"; exit
fi
docker rm "$NAME" >/dev/null 2>&1 || true
# The guest's VNC and SSH listeners are reachable only through loopback forwards.
DEVICES=()
[[ "$ARCH" == arm64 ]] || DEVICES=(--device /dev/kvm)
docker run -d --name "$NAME" "${DEVICES[@]}" -e BROWSER_VM_ARCH="$ARCH" -e BROWSER_VM_VCPUS="$VCPUS" --security-opt label=disable \
 --user "$(id -u):$(id -g)" \
 -p "127.0.0.1:$WEB_PORT:6080" -p "127.0.0.1:$SSH_PORT:2222" \
 -v "$WORK:/work:rw" "$IMAGE" bash -euc '
 if [[ ! -f /work/desktop.qcow2 ]]; then
  qemu-img create -f qcow2 -F qcow2 -b /work/noble-server-cloudimg-${BROWSER_VM_ARCH}.img /work/desktop.qcow2 12G
 fi
 cloud-localds /work/seed.img /work/user-data /work/meta-data
 websockify --web=/usr/share/novnc 6080 localhost:5901 &
 if [[ "$BROWSER_VM_ARCH" == arm64 ]]; then
  QEMU=(qemu-system-aarch64 -machine virt -accel tcg,thread=multi -cpu max -bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd)
 else
  QEMU=(qemu-system-x86_64 -enable-kvm -cpu host)
 fi
 exec "${QEMU[@]}" -smp "$BROWSER_VM_VCPUS" -m 4096 \
  -drive file=/work/desktop.qcow2,format=qcow2,if=virtio \
  -drive file=/work/seed.img,format=raw,if=virtio,readonly=on \
  -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::5901-:5900 \
  -device virtio-net-pci,netdev=net0 -display none -serial stdio -monitor none
 '
echo "Browser: http://127.0.0.1:$WEB_PORT/vnc.html?autoconnect=true&resize=scale"
echo 'First boot installs Chrome and the desktop; allow several minutes.'
echo "VM files and any saved browser logins remain under $WORK (not tracked in Git)."
