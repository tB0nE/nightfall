FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qemu-system-x86 qemu-system-arm qemu-efi-aarch64 qemu-utils cloud-image-utils curl ca-certificates novnc websockify openssh-client && rm -rf /var/lib/apt/lists/*
WORKDIR /work
