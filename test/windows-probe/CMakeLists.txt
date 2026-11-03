cmake_minimum_required(VERSION 3.21)
project(meteor_windows_xr_probe LANGUAGES CXX)
add_executable(meteor-dxgi-composite ../windows_dxgi_composite.cpp)
target_compile_features(meteor-dxgi-composite PRIVATE cxx_std_17)
target_link_libraries(meteor-dxgi-composite PRIVATE d3d11 dxgi)
find_package(Vulkan REQUIRED)
set(OPENXR_SOURCE "" CACHE PATH "Khronos OpenXR SDK source")
set(OPENXR_BUILD "" CACHE PATH "Khronos OpenXR SDK build")
add_executable(meteor-runtime-probe ../monado_runtime_probe.cpp)
target_compile_features(meteor-runtime-probe PRIVATE cxx_std_17)
target_include_directories(meteor-runtime-probe PRIVATE "${OPENXR_BUILD}/include" "${OPENXR_SOURCE}/include")
target_link_libraries(meteor-runtime-probe PRIVATE Vulkan::Vulkan "${OPENXR_BUILD}/src/loader/Release/openxr_loader.lib")
set(NV_CODEC_HEADERS "" CACHE PATH "nv-codec-headers include/ffnvcodec directory")
if(NV_CODEC_HEADERS)
    add_executable(meteor-vulkan-nvenc-probe ../meteor_vulkan_nvenc_probe.cpp)
    target_compile_features(meteor-vulkan-nvenc-probe PRIVATE cxx_std_17)
    target_include_directories(meteor-vulkan-nvenc-probe PRIVATE "${NV_CODEC_HEADERS}")
    target_link_libraries(meteor-vulkan-nvenc-probe PRIVATE Vulkan::Vulkan)
    foreach(stage vert frag)
        add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/meteor_quad.${stage}.h"
            COMMAND "${Vulkan_GLSLANG_VALIDATOR_EXECUTABLE}" -V --vn "meteor_quad_${stage}"
                "${CMAKE_CURRENT_SOURCE_DIR}/../meteor_quad.${stage}"
                -o "${CMAKE_CURRENT_BINARY_DIR}/meteor_quad.${stage}.h"
            DEPENDS "../meteor_quad.${stage}")
    endforeach()
    add_library(meteor-windows-nvenc SHARED ../meteor_vulkan_nvenc_probe.cpp
        "${CMAKE_CURRENT_BINARY_DIR}/meteor_quad.vert.h"
        "${CMAKE_CURRENT_BINARY_DIR}/meteor_quad.frag.h")
    set_target_properties(meteor-windows-nvenc PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)
    target_compile_features(meteor-windows-nvenc PRIVATE cxx_std_17)
    target_compile_definitions(meteor-windows-nvenc PRIVATE METEOR_MONADO_BRIDGE)
    target_include_directories(meteor-windows-nvenc PRIVATE "${NV_CODEC_HEADERS}" "${CMAKE_CURRENT_BINARY_DIR}")
    target_link_libraries(meteor-windows-nvenc PRIVATE Vulkan::Vulkan)
endif()
