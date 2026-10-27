#pragma once
#include "vda_settings.h"
#include "vda_vulkan_tensorcore.h"
#include "vda_portable_gemm.h"
inline ncnn::Layer* vda_create_gemm() {
    if (vda_setting("VDA_PROBE_TENSORCORE")) return new VdaTensorCoreGemm;
    if (vda_setting("VDA_PROBE_PORTABLE_GEMM")) return new VdaPortableGemm;
    return ncnn::create_layer_vulkan("Gemm");
}
