# Desktop browser VM experiment

First stage of [the Quest browser investigation](../../../docs/research/quest-local-drm-browser.md).
This tests Linux Chrome in a desktop VM; it does not establish Quest ARM64 support.

Requires Docker, accessible `/dev/kvm`, curl, sha256sum and ssh-keygen. Run from
this checkout:

```sh
bash tools/experiments/browser-vm/run.sh start
bash tools/experiments/browser-vm/run.sh status
bash tools/experiments/browser-vm/run.sh logs
bash tools/experiments/browser-vm/run.sh stop
```

First boot downloads Ubuntu's official cloud image, installs a lightweight
Fluxbox desktop and official Google Chrome. Allow several minutes. The VM uses
4 vCPUs, 4 GiB RAM, software graphics and a sparse 12 GiB disk. It does not pass
through or reconfigure host GPUs. Chrome runs as an ordinary user without
turning off its browser sandbox.

Open <http://127.0.0.1:6080/vnc.html?autoconnect=true&resize=scale> for the desktop.
Chrome starts at Netflix; sign in yourself and check whether playback starts and
whether video is visible over the remote desktop. noVNC does not carry audio.
Do not interpret silence there as a DRM/audio failure.

The ports (6080 web desktop, 2223 guest SSH) bind only to host loopback. The
passwordless guest VNC service is not published directly. VM files, browser
profiles and the generated SSH key live in ignored `.build-cache/browser-drm-vm/`.
Stopping preserves them, including any website logins. Do not publish this cache.
The guest user has passwordless sudo inside the disposable VM.

No Netflix playback has been verified by the agent. A successful x86 desktop test
still needs separate ARM64/browser and Quest execution tests.

## ARM64 browser baseline

Build the tools image again after updating the Dockerfile, then start a separate
ARM64 guest:

```sh
docker build -t nightfall-browser-vm-tools:ubuntu24.04 tools/experiments/browser-vm
BROWSER_VM_ARCH=arm64 bash tools/experiments/browser-vm/run.sh start
```

Open <http://127.0.0.1:6081/vnc.html?autoconnect=true&resize=scale>.
This uses one emulated CPU, official Ubuntu ARM64 and Chrome ARM64 with QEMU system emulation
(TCG), not host KVM. First boot and browsing can be much slower than x86. The
browser profile, disk and SSH key are separate, in
`.build-cache/browser-drm-vm-arm64/`; SSH uses host loopback port 2224. Pass the
same `BROWSER_VM_ARCH=arm64` for `status`, `logs` or `stop`. The x86 VM keeps its
existing ports and saved state.

This establishes ARM64 Linux browser behavior on a generic emulated machine;
it does not reproduce Android/PRoot restrictions or establish Quest performance.
