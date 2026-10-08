# Installs CMake-built dependencies (libopus, through audiopus_sys) into lib/,
# where their build scripts look. GNUInstallDirs picks lib64 on Fedora.
set(CMAKE_INSTALL_LIBDIR lib CACHE PATH "Library directory")
