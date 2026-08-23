cmake_minimum_required(VERSION 3.21)

set(LIBNAME "nightfall-stream" CACHE STRING "Library name")

if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    if(DEFINED ENV{VCPKG_ROOT})
        set(CMAKE_TOOLCHAIN_FILE "$ENV{VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" CACHE STRING "")
    endif()
endif()

project(${LIBNAME} LANGUAGES CXX)
include(CTest)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(ANDROID)
    set(TARGET_PLATFORM "android")
    add_compile_definitions("pthread_cancel(x)=0")
    remove_definitions(-D_WIN32)
elseif(CMAKE_SYSTEM_NAME STREQUAL "SteamOS" OR NIGHTFALL_PLATFORM STREQUAL "steamos")
    set(TARGET_PLATFORM "steamos")
    set(CMAKE_SYSTEM_NAME "Linux")
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

set(PLATFORM_ID "${TARGET_PLATFORM}.${ACTUAL_ARCH}")

find_package(FFMPEG REQUIRED)
find_package(unofficial-godot-cpp CONFIG REQUIRED)
find_package(moonlight-common-c CONFIG REQUIRED)
find_package(OpenSSL REQUIRED)
find_package(CURL REQUIRED)
find_package(Opus REQUIRED)

if(TARGET_PLATFORM STREQUAL "steamos" OR TARGET_PLATFORM STREQUAL "linux")
    find_package(PkgConfig)
    if(PkgConfig_FOUND)
        pkg_check_modules(AVAHI QUIET avahi-client)
        pkg_check_modules(PIPEWIRE QUIET IMPORTED_TARGET libpipewire-0.3)
        pkg_check_modules(SYSTEMD QUIET IMPORTED_TARGET libsystemd)
    endif()
    find_package(X11 QUIET)
endif()

# Native AI-3D depth estimation on Linux (2026-08-20) - Android's depth pipeline
# calls TFLite via JNI into DepthEstimator.java; there's no JVM on desktop Linux,
# so this needs a direct C++ TFLite dependency instead. No vcpkg tensorflow-lite
# port exists (only the full Bazel-built "tensorflow"/"tensorflow-cc" ports,
# hours to build from source - the wrong tool here), so vendor TFLite's own
# official standalone CMake build directly (tensorflow/lite has first-class
# CMake support independent of Bazel/full TF - see
# tensorflow.org/lite/guide/build_cmake) via FetchContent. Pinned to v2.17.0 to
# match the Android build's own org.tensorflow:tensorflow-lite Gradle dependency
# (see build.sh) for op-version/behavior parity between platforms. Linux only
# (not steamos) - matches this feature's initial scope.
if(TARGET_PLATFORM STREQUAL "linux")
    include(FetchContent)
    FetchContent_Declare(
        tensorflow
        GIT_REPOSITORY https://github.com/tensorflow/tensorflow.git
        GIT_TAG v2.17.0
        GIT_SHALLOW TRUE
    )
    # TFLite 2.17's standalone CMake target expects XNNPACK's transitive
    # FetchContent sources to be pre-populated, but its own entry point does
    # not do that when embedded this way. Keep the portable builtin CPU
    # kernels for now; Android keeps its platform XNNPACK delegate.
    set(TFLITE_ENABLE_XNNPACK OFF CACHE BOOL "" FORCE)
    FetchContent_GetProperties(tensorflow)
    if(NOT tensorflow_POPULATED)
        FetchContent_Populate(tensorflow)
        # A previously interrupted TFLite configure can cache a nonexistent
        # pthreadpool source directory. Let TFLite's bundled downloader restore
        # its pinned dependency on each fresh configure instead.
        unset(PTHREADPOOL_SOURCE_DIR)
        unset(PTHREADPOOL_SOURCE_DIR CACHE)
        unset(FXDIV_SOURCE_DIR)
        unset(FXDIV_SOURCE_DIR CACHE)
        # TFLite's own CMakeLists.txt is a standalone entry point (not the full
        # TF build) - produces a "tensorflow-lite" target with public headers,
        # FetchContent-pulling its own small deps (flatbuffers, ruy, xnnpack,
        # etc.) internally. EXCLUDE_FROM_ALL so its own test/tool targets don't
        # build as part of our default target.
        add_subdirectory("${tensorflow_SOURCE_DIR}/tensorflow/lite" "${CMAKE_CURRENT_BINARY_DIR}/tflite-build" EXCLUDE_FROM_ALL)
    endif()
endif()

if(DEFINED GODOTCPP_SUFFIX AND NOT GODOTCPP_SUFFIX STREQUAL "")
    set(GODOTCPP_SUFFIX_INTERNAL "${GODOTCPP_SUFFIX}")
elseif(DEFINED ENV{GODOTCPP_SUFFIX})
    set(GODOTCPP_SUFFIX_INTERNAL "$ENV{GODOTCPP_SUFFIX}")
else()
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
endif()

add_library(${LIBNAME} SHARED)

file(GLOB_RECURSE SOURCE_FILES CONFIGURE_DEPENDS "src/*.cpp" "src/*.h")
if(ANDROID)
    # These are Linux-only native TFLite sources. Android uses DepthEstimator.java
    # through the JNI bridge and does not ship TensorFlow Lite C++ headers.
    list(REMOVE_ITEM SOURCE_FILES
        "${CMAKE_CURRENT_SOURCE_DIR}/src/video/midas_depth_engine.cpp"
        "${CMAKE_CURRENT_SOURCE_DIR}/src/video/midas_test_main.cpp")
endif()
target_sources(${LIBNAME} PRIVATE ${SOURCE_FILES})

target_compile_features(${LIBNAME} PRIVATE cxx_std_17)
target_include_directories(${LIBNAME} PRIVATE src include)
target_include_directories(${LIBNAME} PRIVATE ${FFMPEG_INCLUDE_DIRS})

if(MSVC)
    set_property(TARGET ${LIBNAME} PROPERTY MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
    target_compile_options(${LIBNAME} PRIVATE /W4)
else()
    target_compile_options(${LIBNAME} PRIVATE -Wall -Wextra -Wno-unused-parameter)
endif()

target_compile_definitions(${LIBNAME} PRIVATE
    NIGHTFALL_PLATFORM_${TARGET_PLATFORM}
    $<$<CONFIG:Debug>:NIGHTFALL_DEBUG>
)

if(TARGET_PLATFORM STREQUAL "steamos" OR TARGET_PLATFORM STREQUAL "linux")
    target_compile_definitions(${LIBNAME} PRIVATE NIGHTFALL_PLATFORM_LINUX)
    if(AVAHI_FOUND)
        target_compile_definitions(${LIBNAME} PRIVATE NIGHTFALL_HAS_AVAHI)
    endif()
endif()

target_compile_definitions(${LIBNAME} PRIVATE CURL_STATICLIB)

target_link_libraries(${LIBNAME}
    PRIVATE
    unofficial::godot::cpp
    moonlight-common-c::moonlight-common-c
    CURL::libcurl
    OpenSSL::SSL OpenSSL::Crypto
    Opus::opus
    ${FFMPEG_LIBRARIES}
)

if(TARGET_PLATFORM STREQUAL "steamos" OR TARGET_PLATFORM STREQUAL "linux")
    target_link_libraries(${LIBNAME} PRIVATE atomic m pthread dl)
    if(AVAHI_FOUND)
        target_link_libraries(${LIBNAME} PRIVATE ${AVAHI_LIBRARIES})
        target_include_directories(${LIBNAME} PRIVATE ${AVAHI_INCLUDE_DIRS})
    endif()
    if(PIPEWIRE_FOUND)
        target_link_libraries(${LIBNAME} PRIVATE PkgConfig::PIPEWIRE)
        target_compile_definitions(${LIBNAME} PRIVATE NIGHTFALL_HAS_PIPEWIRE)
    endif()
    if(SYSTEMD_FOUND)
        target_link_libraries(${LIBNAME} PRIVATE PkgConfig::SYSTEMD)
        target_compile_definitions(${LIBNAME} PRIVATE NIGHTFALL_HAS_SYSTEMD)
    endif()
    if(X11_FOUND)
        target_link_libraries(${LIBNAME} PRIVATE X11::X11 X11::Xext)
        target_compile_definitions(${LIBNAME} PRIVATE NIGHTFALL_HAS_X11)
        # RandR monitor enumeration for local-capture mode's per-monitor
        # selection (2026-08-20, x11_capture.cpp's select_capture_region()) -
        # without this the local-capture zero-copy path always grabbed the
        # WHOLE X11 root window (every connected monitor unioned together),
        # not just whichever one Sunshine is actually configured to stream.
        if(X11_Xrandr_FOUND)
            target_link_libraries(${LIBNAME} PRIVATE X11::Xrandr)
            target_compile_definitions(${LIBNAME} PRIVATE NIGHTFALL_HAS_XRANDR)
        endif()
    endif()
    if(TARGET_PLATFORM STREQUAL "linux")
        set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-Bsymbolic")
        target_link_libraries(${LIBNAME} PRIVATE tensorflow-lite)

        # Standalone MidasDepthEngine reproduction harness (2026-08-20 segfault
        # investigation) - NOT part of the normal build, opt-in only
        # (-DNIGHTFALL_BUILD_MIDAS_TEST=ON) so it doesn't cost anything in the
        # real build.sh flow. Lets the engine be exercised/debugged (gdb)
        # directly without needing a live Sunshine stream or the app's UI.
        if(NIGHTFALL_BUILD_MIDAS_TEST)
            add_executable(midas_test src/video/midas_test_main.cpp src/video/midas_depth_engine.cpp)
            target_compile_features(midas_test PRIVATE cxx_std_17)
            target_include_directories(midas_test PRIVATE src)
            target_link_libraries(midas_test PRIVATE tensorflow-lite pthread)
        endif()
    endif()
endif()

if(ANDROID)
    target_compile_definitions(${LIBNAME} PRIVATE _FORTIFY_SOURCE=0)
    target_link_libraries(${LIBNAME} PRIVATE atomic m log dl android mediandk GLESv3)
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

set(GODOT_ADDON_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../addons/nightfall-stream/bin/${TARGET_PLATFORM}")
add_custom_command(TARGET ${LIBNAME} POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${GODOT_ADDON_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "$<TARGET_FILE:${LIBNAME}>"
        "${GODOT_ADDON_DIR}/$<TARGET_FILE_NAME:${LIBNAME}>"
    COMMENT "Deploying to Godot addon directory..."
)

# Standalone CLI stream test (desktop only)
if(TARGET_PLATFORM STREQUAL "linux" OR TARGET_PLATFORM STREQUAL "steamos")
    set(TEST_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../../test/stream_test.cpp")
    if(EXISTS "${TEST_SRC}")
        add_executable(stream_test "${TEST_SRC}")
        target_compile_features(stream_test PRIVATE cxx_std_17)
        target_include_directories(stream_test PRIVATE src include ${FFMPEG_INCLUDE_DIRS})
        target_link_libraries(stream_test PRIVATE
            moonlight-common-c::moonlight-common-c
            ${FFMPEG_LIBRARIES}
            pthread dl
        )

        if(BUILD_TESTING)
            add_executable(decode_unit_queue_test
                "${CMAKE_CURRENT_SOURCE_DIR}/../../test/decode_unit_queue_test.cpp")
            target_compile_features(decode_unit_queue_test PRIVATE cxx_std_17)
            target_include_directories(decode_unit_queue_test PRIVATE src ${FFMPEG_INCLUDE_DIRS})
            target_link_libraries(decode_unit_queue_test PRIVATE ${FFMPEG_LIBRARIES})
            add_test(NAME decode_unit_queue COMMAND decode_unit_queue_test)
        endif()
    endif()
endif()
