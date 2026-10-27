#pragma once
// One dispatch into an app-owned storage buffer, then GPU copy to the OpenXR
// swapchain. Caller owns completion before reuse/destruction.
struct MeteorGpuScene {
    VkDevice device;
    VkDescriptorSetLayout set_layout{};
    VkPipelineLayout layout{};
    VkPipeline pipeline{};
    VkDescriptorPool descriptor_pool{};
    VkDescriptorSet descriptor{};
    struct Parameters { float origin[4], x[4], y[4], z[4], tangents[4]; uint32_t extent[4]; };
    static_assert(sizeof(Parameters)==96);
    MeteorGpuScene(VkDevice dev, VkBuffer output, const char *shader_path): device(dev) {
        std::ifstream file(shader_path,std::ios::binary|std::ios::ate);
        auto size=file.tellg();
        if(!file || size<=0 || size%4) { std::fprintf(stderr,"Invalid GPU scene shader\n"); std::exit(1); }
        std::vector<uint32_t> code(size_t(size)/4);
        file.seekg(0); file.read(reinterpret_cast<char *>(code.data()),size);
        if(!file) { std::fprintf(stderr,"Cannot read GPU scene shader\n"); std::exit(1); }
        VkShaderModuleCreateInfo module_info{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
        module_info.codeSize=size_t(size); module_info.pCode=code.data();
        VkShaderModule module;
        vk_check(vkCreateShaderModule(device,&module_info,nullptr,&module),"scene shader");
        VkDescriptorSetLayoutBinding binding{};
        binding.binding=0; binding.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        binding.descriptorCount=1; binding.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT;
        VkDescriptorSetLayoutCreateInfo set_info{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
        set_info.bindingCount=1; set_info.pBindings=&binding;
        vk_check(vkCreateDescriptorSetLayout(device,&set_info,nullptr,&set_layout),"scene descriptor layout");
        VkPushConstantRange push{VK_SHADER_STAGE_COMPUTE_BIT,0,sizeof(Parameters)};
        VkPipelineLayoutCreateInfo layout_info{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
        layout_info.setLayoutCount=1; layout_info.pSetLayouts=&set_layout;
        layout_info.pushConstantRangeCount=1; layout_info.pPushConstantRanges=&push;
        vk_check(vkCreatePipelineLayout(device,&layout_info,nullptr,&layout),"scene pipeline layout");
        VkComputePipelineCreateInfo compute{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};
        compute.layout=layout; compute.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};
        compute.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT; compute.stage.module=module; compute.stage.pName="main";
        vk_check(vkCreateComputePipelines(device,VK_NULL_HANDLE,1,&compute,nullptr,&pipeline),"scene compute pipeline");
        vkDestroyShaderModule(device,module,nullptr);
        VkDescriptorPoolSize pool_size{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1};
        VkDescriptorPoolCreateInfo pool_info{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        pool_info.maxSets=1; pool_info.poolSizeCount=1; pool_info.pPoolSizes=&pool_size;
        vk_check(vkCreateDescriptorPool(device,&pool_info,nullptr,&descriptor_pool),"scene descriptor pool");
        VkDescriptorSetAllocateInfo alloc{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        alloc.descriptorPool=descriptor_pool; alloc.descriptorSetCount=1; alloc.pSetLayouts=&set_layout;
        vk_check(vkAllocateDescriptorSets(device,&alloc,&descriptor),"scene descriptor");
        VkDescriptorBufferInfo buffer_info{output,0,VK_WHOLE_SIZE};
        VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
        write.dstSet=descriptor; write.descriptorCount=1; write.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        write.pBufferInfo=&buffer_info;
        vkUpdateDescriptorSets(device,1,&write,0,nullptr);
    }
    void render(VkCommandBuffer command,const MeteorSceneCamera &camera,uint32_t width,uint32_t height) {
        auto vec=[](float *out,MeteorSceneVec v) { out[0]=v.x; out[1]=v.y; out[2]=v.z; };
        Parameters p{}; vec(p.origin,camera.origin); vec(p.x,camera.basis_x);
        vec(p.y,camera.basis_y); vec(p.z,camera.basis_z);
        p.tangents[0]=camera.left; p.tangents[1]=camera.right; p.tangents[2]=camera.up; p.tangents[3]=camera.down;
        p.extent[0]=width; p.extent[1]=height;
        vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_COMPUTE,pipeline);
        vkCmdBindDescriptorSets(command,VK_PIPELINE_BIND_POINT_COMPUTE,layout,0,1,&descriptor,0,nullptr);
        vkCmdPushConstants(command,layout,VK_SHADER_STAGE_COMPUTE_BIT,0,sizeof(p),&p);
        vkCmdDispatch(command,(width+7)/8,(height+7)/8,1);
    }
    ~MeteorGpuScene() {
        vkDestroyDescriptorPool(device,descriptor_pool,nullptr);
        vkDestroyPipeline(device,pipeline,nullptr); vkDestroyPipelineLayout(device,layout,nullptr);
        vkDestroyDescriptorSetLayout(device,set_layout,nullptr);
    }
};
