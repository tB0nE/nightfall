#!/usr/bin/env bash
set -euo pipefail
mkdir -p /out/source
cp -a --remove-destination /source/. /out/source/
patch --batch --fuzz=0 -d /out/source -p1 < /tests/hello_xr_diagnostic.patch
cmake -S /out/source -B /out/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_TESTS=ON -DBUILD_API_LAYERS=OFF -DBUILD_CONFORMANCE_TESTS=OFF \
    -DBUILD_SDK_TESTS=ON -DBUILD_LOADER=ON -DCMAKE_DISABLE_FIND_PACKAGE_OpenGL=TRUE \
    -DCMAKE_DISABLE_FIND_PACKAGE_EGL=TRUE \
    -DCMAKE_CXX_FLAGS=-DXR_USE_TIMESPEC -DCMAKE_BUILD_RPATH_USE_ORIGIN=ON
cmake --build /out/build --target hello_xr -j 4
