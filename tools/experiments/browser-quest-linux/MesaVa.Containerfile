FROM docker.io/library/ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN dpkg --add-architecture arm64 && sed -i '/^Types: deb/a Architectures: amd64' /etc/apt/sources.list.d/ubuntu.sources && \
    printf 'deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports noble main universe\ndeb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports noble-updates main universe\n' > /etc/apt/sources.list.d/arm64.list && \
    apt-get update && apt-get install -y --no-install-recommends \
      build-essential gcc-aarch64-linux-gnu g++-aarch64-linux-gnu pkg-config ninja-build \
      python3 python3-pip python3-venv python3-mako python3-yaml python3-packaging \
      bison flex libdrm-dev:arm64 libva-dev:arm64 libexpat1-dev:arm64 \
      zlib1g-dev:arm64 libzstd-dev:arm64 libelf-dev:arm64 libudev-dev:arm64 && \
    python3 -m venv --system-site-packages /opt/meson && /opt/meson/bin/pip install 'meson==1.10.0' && \
    rm -rf /var/lib/apt/lists/*
ENV PATH=/opt/meson/bin:$PATH
# Chrome needs the matching X11/EGL presentation stack, not only a VA library.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libx11-dev:arm64 libx11-xcb-dev:arm64 libxext-dev:arm64 libxfixes-dev:arm64 \
      libxrandr-dev:arm64 libxxf86vm-dev:arm64 libxshmfence-dev:arm64 libglvnd-dev:arm64 \
      libxcb-dri2-0-dev:arm64 libxcb-dri3-dev:arm64 libxcb-glx0-dev:arm64 \
      libxcb-present-dev:arm64 libxcb-randr0-dev:arm64 libxcb-shm0-dev:arm64 \
      libxcb-sync-dev:arm64 libxcb-xfixes0-dev:arm64 && rm -rf /var/lib/apt/lists/*
