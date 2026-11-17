#!/usr/bin/env bash
# Run inside Dockerfile.cross, with addon sources mounted at /source and cache at /work.
set -euo pipefail
mkdir -p /work/source
(cd /source && tar --exclude='./build*' --exclude='./bin' --exclude='./third_party/pyrowave' -cf - .) | (cd /work/source && tar -xf -)
cd /work/source
export VCPKG_DEFAULT_TRIPLET=arm64-linux
export PKG_CONFIG_LIBDIR=/work/native/vcpkg_installed/arm64-linux/lib/pkgconfig
cmake --preset linux -B /work/native -DCMAKE_BUILD_TYPE=Release \
  -DNIGHTFALL_LOCAL_DEPTH=OFF -DNIGHTFALL_BUILD_MIDAS_TEST=OFF -DBUILD_TESTING=OFF \
  -DVCPKG_MAX_CONCURRENCY=8 -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
  -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++ \
  -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=FALSE -DCMAKE_DISABLE_FIND_PACKAGE_X11=TRUE
cmake --build /work/native --parallel 8
aarch64-linux-gnu-strip --strip-debug /work/native/bin/linux/libnightfall-stream.linux.template_release.arm64.so
