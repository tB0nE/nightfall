#pragma once
#include <net.h>
#include <memory>
#include <stdexcept>
// Integer IEEE-754 half classification avoids compiler finite-math assumptions.
inline std::unique_ptr<ncnn::Pipeline> vda_finite_pipeline(const ncnn::VulkanDevice* device,const ncnn::Option& opt) {
    const char* check=R"glsl(
#version 450
layout(local_size_x_id=233,local_size_y_id=234,local_size_z_id=235) in;
layout(binding=0) readonly buffer Values {uint words[];};
layout(binding=1) buffer Flag {uint bad;};
layout(push_constant) uniform parameter {int count;} p;
void main() {int i=int(gl_GlobalInvocationID.x);if (i<p.count) {uint v=words[i];if ((v&0x7c00u)==0x7c00u || (v&0x7c000000u)==0x7c000000u) atomicOr(bad,1u);}}
)glsl";
    std::vector<uint32_t> spirv;
    if (ncnn::compile_spirv_module(check,opt,spirv)) throw std::runtime_error("Cannot compile VDA finite check");
    auto finite=std::make_unique<ncnn::Pipeline>(device);finite->set_local_size_xyz(128,1,1);
    std::vector<ncnn::vk_specialization_type> specs(3);specs[0].i=128;specs[1].i=1;specs[2].i=1;
    if (finite->create(spirv.data(),spirv.size()*4,specs)) throw std::runtime_error("Cannot create VDA finite check");
    return finite;
}
