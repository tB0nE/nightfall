vcpkg_check_linkage(ONLY_STATIC_LIBRARY)
# Download the xlnt source code
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO moonlight-stream/moonlight-common-c
    REF 7b026e77be62175104640e7e722b758df6d3d0d7
    SHA512 116340530ed2f431af345bad93f4be0168a04f1846ed5e17d352a46121be6bcc2c8e24d19e74eb40aa3bf5066e694ea6a28f4d63adfa5e74104c25bd2297d4d5
    HEAD_REF master
    )
    
vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH_LIBENET
    REPO cgutman/enet
    REF dea6fb5414b180908b58c0293c831105b5d124dd
    SHA512 c072acff252e495032ddf2f2a414a3644d7d4ca3abf6b01204021a61dfc19cf9a621ab1dface47ebb337f0454cacb8fee877a564b782b49fb868b5b95e7f36ae
    HEAD_REF moonlight
)

file(COPY "${SOURCE_PATH_LIBENET}/" DESTINATION "${SOURCE_PATH}/enet")

vcpkg_apply_patches(
    SOURCE_PATH ${SOURCE_PATH}
    PATCHES
        0001-add-install-rules.patch
        0002-fix-clang-multiversioning-headers.patch
        0003-add-pyrowave-codec.patch
)

set(BUILD_SHARED_LIBS OFF)  # 强制构建静态库

vcpkg_cmake_configure(
    SOURCE_PATH "${SOURCE_PATH}"
    OPTIONS
        -DBUILD_SHARED_LIBS=OFF  # 传递给CMake
        -DUSE_MBEDTLS=OFF        # 使用OpenSSL（vcpkg默认）
)

vcpkg_cmake_install()
vcpkg_cmake_config_fixup(PACKAGE_NAME moonlight-common-c)
vcpkg_copy_pdbs()
vcpkg_fixup_pkgconfig()  # 修复pkg-config文件

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE.txt")