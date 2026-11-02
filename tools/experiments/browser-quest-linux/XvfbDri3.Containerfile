FROM localhost/nightfall-mesa-va-builder:latest
RUN apt-get update && apt-get install -y --no-install-recommends \
      x11proto-dev xtrans-dev xutils-dev xfonts-utils x11-xkb-utils \
      mesa-common-dev:arm64 libpixman-1-dev:arm64 libepoxy-dev:arm64 libgbm-dev:arm64 libxfont-dev:arm64 \
      libxkbfile-dev:arm64 libxau-dev:arm64 libxdmcp-dev:arm64 libxdamage-dev:arm64 \
      libxres-dev:arm64 libxmu-dev:arm64 libssl-dev:arm64 && rm -rf /var/lib/apt/lists/*
