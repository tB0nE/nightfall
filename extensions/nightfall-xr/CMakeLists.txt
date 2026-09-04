cmake_minimum_required(VERSION 3.21)

set(LIBNAME "nightfall-xr" CACHE STRING "Library name")

if(NOT CMAKE_SYSTEM_NAME STREQUAL "Android" AND NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    if(DEFINED ENV{VCPKG_ROOT})
        set(CMAKE_TOOLCHAIN_FILE "$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" CACHE STRING "")
    endif()
endif()

project(${LIBNAME} LANGUAGES CXX C)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_C_STANDARD 99)

if(ANDROID)
    set(TARGET_PLATFORM "android")
else()
    set(TARGET_PLATFORM "linux")
endif()

if(ANDROID)
    if(ANDROID_ABI STREQUAL "arm64-v8a")
        set(ACTUAL_ARCH "arm64")
    elseif(ANDROID_ABI STREQUAL "x86_64")
        set(ACTUAL_ARCH "x86_64")
    else()
        set(ACTUAL_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
    endif()
else()
    if(CMAKE_SYSTEM_PROCESSOR STREQUAL "AMD64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "amd64")
        set(ACTUAL_ARCH "x86_64")
    elseif(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
        set(ACTUAL_ARCH "arm64")
    else()
        set(ACTUAL_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
    endif()
endif()

# vcpkg's stock godot-cpp package binds against a bundled extension_api.json
# that excludes the OpenXR module entirely (verified: zero godot_cpp/classes/
# open_xr_*.hpp files in that package) -- so OpenXRExtensionWrapperExtension,
# the mechanism nightfall-xr needs to inject composition layers into Godot's own
# xrEndFrame (see README.md), isn't available through it at all. This
# is unrelated to our engine patch; stock Godot's own OpenXR classes are just
# missing from that dump. GODOTCPP_CUSTOM_DIR points at a godot-cpp checkout
# built with `custom_api_file=<dump from our own patched engine>`, which does
# have them (see extensions/nightfall-xr/README or session notes for the build
# recipe). Only Android needs this -- Linux stays on Godot's own composition
# layer path per the plan and links vcpkg's stock godot-cpp as before.
set(GODOTCPP_CUSTOM_DIR "" CACHE PATH "Path to a godot-cpp checkout built with a custom_api_file dump from the patched engine (required on Android for OpenXRExtensionWrapperExtension)")
set(GODOT_SOURCE_DIR "" CACHE PATH "Path to the matching Godot source tree (used for OpenXR headers on Android)")

if(ANDROID AND GODOTCPP_CUSTOM_DIR)
    set(GODOTCPP_USE_CUSTOM TRUE)
else()
    set(GODOTCPP_USE_CUSTOM FALSE)
    find_package(unofficial-godot-cpp CONFIG REQUIRED)
endif()

# OpenXR loader: the C entry points live in the loader Godot already ships in
# its own .so; on Android we only need the headers to compile against, and the
# symbols resolve at runtime through the already-loaded OpenXR runtime/loader.
# vcpkg provides openxr-loader for the native build; for Android we compile the
# C node against the Khronos headers and link nothing extra (the loader is
# present in-process via the OpenXR runtime).
if(ANDROID)
    # Headers come from the vendored openxr thirdparty of the patched engine
    # build, but for an out-of-tree extension we vendor them here instead.
    # Android's toolchain normally roots find_path() inside the NDK sysroot;
    # this is an intentional host-source include and must bypass that remap.
    find_path(OPENXR_INCLUDE_DIR openxr/openxr.h
        HINTS "${GODOT_SOURCE_DIR}/thirdparty/openxr/include"
        NO_CMAKE_FIND_ROOT_PATH)
    if(NOT OPENXR_INCLUDE_DIR)
        message(FATAL_ERROR "OpenXR headers not found; set GODOT_SOURCE_DIR to the matching Godot source tree")
    endif()
else()
    find_package(openxr-loader CONFIG REQUIRED)
endif()

if(DEFINED GODOTCPP_SUFFIX AND NOT GODOTCPP_SUFFIX STREQUAL "")
    set(GODOTCPP_SUFFIX_INTERNAL "${GODOTCPP_SUFFIX}")
elseif(DEFINED ENV{GODOTCPP_SUFFIX})
    set(GODOTCPP_SUFFIX_INTERNAL "$ENV{GODOTCPP_SUFFIX}")
elseif(NOT GODOTCPP_USE_CUSTOM)
    get_target_property(PROP_SUFFIX unofficial::godot::cpp GODOTCPP_SUFFIX)
    if(PROP_SUFFIX AND NOT PROP_SUFFIX MATCHES "NOTFOUND")
        set(GODOTCPP_SUFFIX_INTERNAL "${PROP_SUFFIX}")
    else()
        if(CMAKE_BUILD_TYPE STREQUAL "Release")
            set(GODOTCPP_SUFFIX_INTERNAL ".${TARGET_PLATFORM}.template_release.${ACTUAL_ARCH}")
        else()
            set(GODOTCPP_SUFFIX_INTERNAL ".${TARGET_PLATFORM}.template_debug.${ACTUAL_ARCH}")
        endif()
    endif()
else()
    if(CMAKE_BUILD_TYPE STREQUAL "Release")
        set(GODOTCPP_SUFFIX_INTERNAL ".${TARGET_PLATFORM}.template_release.${ACTUAL_ARCH}")
    else()
        set(GODOTCPP_SUFFIX_INTERNAL ".${TARGET_PLATFORM}.template_debug.${ACTUAL_ARCH}")
    endif()
endif()

add_library(${LIBNAME} SHARED)

file(GLOB_RECURSE SOURCE_FILES CONFIGURE_DEPENDS "src/*.cpp" "src/*.h" "src/*.c")
target_sources(${LIBNAME} PRIVATE ${SOURCE_FILES})

target_compile_features(${LIBNAME} PRIVATE cxx_std_17)
target_include_directories(${LIBNAME} PRIVATE src include)
if(OPENXR_INCLUDE_DIR)
    target_include_directories(${LIBNAME} PRIVATE ${OPENXR_INCLUDE_DIR})
endif()
if(GODOTCPP_USE_CUSTOM)
    # BEFORE matters: the vcpkg toolchain file injects vcpkg_installed/.../include
    # as a system include path for every target once it's used at all (our
    # vcpkg.json still lists godot-cpp for the Linux build's sake), regardless
    # of whether find_package(unofficial-godot-cpp) is actually called here --
    # that stock package ships its own, older/different-signature OpenXR
    # bindings which would otherwise silently shadow ours.
    target_include_directories(${LIBNAME} BEFORE PRIVATE
        "${GODOTCPP_CUSTOM_DIR}/include"
        "${GODOTCPP_CUSTOM_DIR}/gen/include"
        "${GODOTCPP_CUSTOM_DIR}/gdextension"
    )
endif()

if(NOT MSVC)
    target_compile_options(${LIBNAME} PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

target_compile_definitions(${LIBNAME} PRIVATE
    NIGHTFALL_PLATFORM_${TARGET_PLATFORM}
    $<$<CONFIG:Debug>:NIGHTFALL_DEBUG>
)

if(GODOTCPP_USE_CUSTOM)
    set(GODOTCPP_CUSTOM_LIB "${GODOTCPP_CUSTOM_DIR}/bin/libgodot-cpp${GODOTCPP_SUFFIX_INTERNAL}.a")
    if(NOT EXISTS "${GODOTCPP_CUSTOM_LIB}")
        message(FATAL_ERROR "Custom godot-cpp static library not found: ${GODOTCPP_CUSTOM_LIB}")
    endif()
    # A raw absolute-path .a isn't treated like a named CMake target for
    # link-order purposes, so a plain PRIVATE link can leave it scanned
    # before the object files that need its symbols. Force a repeated scan.
    target_link_libraries(${LIBNAME} PRIVATE
        "-Wl,--start-group" "${GODOTCPP_CUSTOM_LIB}" "-Wl,--end-group"
    )
else()
    target_link_libraries(${LIBNAME} PRIVATE unofficial::godot::cpp)
endif()
if(ANDROID)
    target_link_libraries(${LIBNAME} PRIVATE atomic m log dl android EGL GLESv3)
else()
    target_link_libraries(${LIBNAME} PRIVATE openxr_loader EGL GLESv3 atomic m pthread dl)
endif()

if(WIN32)
    set_target_properties(${LIBNAME} PROPERTIES
        PREFIX ""
        OUTPUT_NAME "${LIBNAME}${GODOTCPP_SUFFIX_INTERNAL}"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/bin/${TARGET_PLATFORM}"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/bin/${TARGET_PLATFORM}"
    )
else()
    set_target_properties(${LIBNAME} PROPERTIES
        PREFIX "lib"
        OUTPUT_NAME "${LIBNAME}${GODOTCPP_SUFFIX_INTERNAL}"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/bin/${TARGET_PLATFORM}"
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/bin/${TARGET_PLATFORM}"
    )
endif()

# Mirrors nightfall-stream's own deploy step, keeping this .so next to
# bin/nightfall-xr.gdextension so the extension dir stays self-contained.
set(GODOT_ADDON_DIR "${CMAKE_CURRENT_SOURCE_DIR}/bin/${TARGET_PLATFORM}")
add_custom_command(TARGET ${LIBNAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${GODOT_ADDON_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "$<TARGET_FILE:${LIBNAME}>"
        "${GODOT_ADDON_DIR}/$<TARGET_FILE_NAME:${LIBNAME}>"
    COMMENT "Deploying to extensions/nightfall-xr/bin/${TARGET_PLATFORM}..."
)
