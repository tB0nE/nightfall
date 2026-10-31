#!/bin/bash
# Runs inside the Quest Linux userspace, not on the host or in the desktop VM.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
test "$(dpkg --print-architecture)" = arm64
mkdir -p /usr/sbin
# No systemd/daemon startup during package installation in this userspace.
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
apt-get -o APT::Sandbox::User=root update
apt-get -o APT::Sandbox::User=root install -y --no-install-recommends \
  ca-certificates curl fluxbox xvfb x11vnc x11-utils dbus-x11 \
  fonts-liberation pulseaudio novnc websockify /tmp/google-chrome-arm64.deb
id browser >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash browser
mkdir -p /home/browser/.cache/nightfall-runtime
chmod 700 /home/browser/.cache/nightfall-runtime
google-chrome-stable --version
echo 'Browser packages installed. Sandbox and playback have not yet been verified.'
