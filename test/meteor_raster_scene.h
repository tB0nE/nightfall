#pragma once
// Rasterized diagnostic workload. Real triangles, asymmetric eye projection,
// per-fragment depth testing; direct writes to acquired OpenXR eye images.
struct MeteorRasterScene {
    VkDevice device;
    VkRenderPass pass{};
    VkPipelineLayout layout{};
    VkPipeline pipeline{};
    VkImage depth{};
    VkDeviceMemory depth_memory{};
    VkImageView depth_view{};
    std::vector<VkImageView> color_views;
    std::vector<VkFramebuffer> framebuffers;
    uint32_t width,height;
    MeteorRasterScene(VkPhysicalDevice gpu,VkDevice dev,uint32_t w,uint32_t h,
        const std::vector<XrSwapchainImageVulkanKHR> (&eyes)[2],const char *directory):device(dev),width(w),height(h) {
        VkFormatProperties format;
        vkGetPhysicalDeviceFormatProperties(gpu,VK_FORMAT_D32_SFLOAT,&format);
        if(!(format.optimalTilingFeatures&VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT)) {
            std::fprintf(stderr,"D32 depth attachments unavailable\n"); std::exit(1);
        }
        VkImageCreateInfo image{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
        image.imageType=VK_IMAGE_TYPE_2D; image.format=VK_FORMAT_D32_SFLOAT; image.extent={w,h,1};
        image.mipLevels=1; image.arrayLayers=1; image.samples=VK_SAMPLE_COUNT_1_BIT;
        image.tiling=VK_IMAGE_TILING_OPTIMAL; image.usage=VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
        vk_check(vkCreateImage(device,&image,nullptr,&depth),"raster depth image");
        VkMemoryRequirements requirements; vkGetImageMemoryRequirements(device,depth,&requirements);
        VkPhysicalDeviceMemoryProperties memory; vkGetPhysicalDeviceMemoryProperties(gpu,&memory);
        uint32_t type=memory.memoryTypeCount;
        for(uint32_t i=0;i<memory.memoryTypeCount;++i)
            if((requirements.memoryTypeBits&(1u<<i)) && (memory.memoryTypes[i].propertyFlags&VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) { type=i; break; }
        if(type==memory.memoryTypeCount) { std::fprintf(stderr,"No device-local depth memory\n"); std::exit(1); }
        VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
        alloc.allocationSize=requirements.size; alloc.memoryTypeIndex=type;
        vk_check(vkAllocateMemory(device,&alloc,nullptr,&depth_memory),"raster depth allocation");
        vk_check(vkBindImageMemory(device,depth,depth_memory,0),"raster depth binding");
        VkImageViewCreateInfo view{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        view.image=depth; view.viewType=VK_IMAGE_VIEW_TYPE_2D; view.format=VK_FORMAT_D32_SFLOAT;
        view.subresourceRange={VK_IMAGE_ASPECT_DEPTH_BIT,0,1,0,1};
        vk_check(vkCreateImageView(device,&view,nullptr,&depth_view),"raster depth view");
        VkAttachmentDescription attachments[2]{};
        attachments[0].format=VK_FORMAT_R8G8B8A8_UNORM; attachments[0].samples=VK_SAMPLE_COUNT_1_BIT;
        attachments[0].loadOp=VK_ATTACHMENT_LOAD_OP_CLEAR; attachments[0].storeOp=VK_ATTACHMENT_STORE_OP_STORE;
        attachments[0].initialLayout=attachments[0].finalLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        attachments[1].format=VK_FORMAT_D32_SFLOAT; attachments[1].samples=VK_SAMPLE_COUNT_1_BIT;
        attachments[1].loadOp=VK_ATTACHMENT_LOAD_OP_CLEAR; attachments[1].storeOp=VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachments[1].initialLayout=VK_IMAGE_LAYOUT_UNDEFINED; attachments[1].finalLayout=VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
        for(auto &attachment:attachments) { attachment.stencilLoadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE; attachment.stencilStoreOp=VK_ATTACHMENT_STORE_OP_DONT_CARE; }
        VkAttachmentReference color{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL},depth_ref{1,VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};
        VkSubpassDescription subpass{}; subpass.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount=1; subpass.pColorAttachments=&color; subpass.pDepthStencilAttachment=&depth_ref;
        VkSubpassDependency dependency{}; dependency.srcSubpass=VK_SUBPASS_EXTERNAL; dependency.dstSubpass=0;
        dependency.srcStageMask=VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
        dependency.dstStageMask=VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT|VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT;
        dependency.srcAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT;
        dependency.dstAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT|VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
        VkRenderPassCreateInfo render_pass{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
        render_pass.attachmentCount=2; render_pass.pAttachments=attachments; render_pass.subpassCount=1; render_pass.pSubpasses=&subpass;
        render_pass.dependencyCount=1; render_pass.pDependencies=&dependency;
        vk_check(vkCreateRenderPass(device,&render_pass,nullptr,&pass),"raster render pass");
        for(const auto &eye:eyes) for(const auto &target:eye) {
            view.image=target.image; view.format=VK_FORMAT_R8G8B8A8_UNORM; view.subresourceRange.aspectMask=VK_IMAGE_ASPECT_COLOR_BIT;
            VkImageView color_view;
            vk_check(vkCreateImageView(device,&view,nullptr,&color_view),"raster eye view"); color_views.push_back(color_view);
            VkImageView views[2]={color_view,depth_view};
            VkFramebufferCreateInfo framebuffer{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
            framebuffer.renderPass=pass; framebuffer.attachmentCount=2; framebuffer.pAttachments=views;
            framebuffer.width=w; framebuffer.height=h; framebuffer.layers=1;
            VkFramebuffer fb; vk_check(vkCreateFramebuffer(device,&framebuffer,nullptr,&fb),"raster framebuffer"); framebuffers.push_back(fb);
        }
        VkPushConstantRange push{VK_SHADER_STAGE_VERTEX_BIT,0,sizeof(MeteorGpuScene::Parameters)};
        VkPipelineLayoutCreateInfo pipeline_layout{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
        pipeline_layout.pushConstantRangeCount=1; pipeline_layout.pPushConstantRanges=&push;
        vk_check(vkCreatePipelineLayout(device,&pipeline_layout,nullptr,&layout),"raster pipeline layout");
        VkShaderModule shaders[2];
        const char *names[2]={"meteor_raster_scene.vert.spv","meteor_raster_scene.frag.spv"};
        VkPipelineShaderStageCreateInfo stages[2]{};
        for(int i=0;i<2;++i) {
            std::ifstream file(std::string(directory)+"/"+names[i],std::ios::binary|std::ios::ate);
            auto size=file.tellg();
            if(!file || size<=0 || size%4) { std::fprintf(stderr,"Invalid raster shader\n"); std::exit(1); }
            std::vector<uint32_t> code(size_t(size)/4); file.seekg(0); file.read(reinterpret_cast<char *>(code.data()),size);
            if(!file) { std::fprintf(stderr,"Cannot read raster shader\n"); std::exit(1); }
            VkShaderModuleCreateInfo module{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; module.codeSize=size_t(size); module.pCode=code.data();
            vk_check(vkCreateShaderModule(device,&module,nullptr,&shaders[i]),"raster shader module");
            stages[i]={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO}; stages[i].module=shaders[i]; stages[i].pName="main";
            stages[i].stage=i==0 ? VK_SHADER_STAGE_VERTEX_BIT : VK_SHADER_STAGE_FRAGMENT_BIT;
        }
        VkPipelineVertexInputStateCreateInfo vertex{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
        VkPipelineInputAssemblyStateCreateInfo assembly{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO}; assembly.topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        VkViewport viewport{0,0,float(w),float(h),0,1}; VkRect2D scissor{{0,0},{w,h}};
        VkPipelineViewportStateCreateInfo viewport_info{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO};
        viewport_info.viewportCount=1; viewport_info.pViewports=&viewport; viewport_info.scissorCount=1; viewport_info.pScissors=&scissor;
        VkPipelineRasterizationStateCreateInfo raster{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
        raster.polygonMode=VK_POLYGON_MODE_FILL; raster.cullMode=VK_CULL_MODE_NONE; raster.lineWidth=1;
        VkPipelineMultisampleStateCreateInfo samples{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO}; samples.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT;
        VkPipelineDepthStencilStateCreateInfo depth_state{VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO};
        depth_state.depthTestEnable=VK_TRUE; depth_state.depthWriteEnable=VK_TRUE; depth_state.depthCompareOp=VK_COMPARE_OP_LESS;
        VkPipelineColorBlendAttachmentState blend{}; blend.colorWriteMask=0xf;
        VkPipelineColorBlendStateCreateInfo colors{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO}; colors.attachmentCount=1; colors.pAttachments=&blend;
        VkGraphicsPipelineCreateInfo graphics{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
        graphics.stageCount=2; graphics.pStages=stages; graphics.pVertexInputState=&vertex; graphics.pInputAssemblyState=&assembly;
        graphics.pViewportState=&viewport_info; graphics.pRasterizationState=&raster; graphics.pMultisampleState=&samples;
        graphics.pDepthStencilState=&depth_state; graphics.pColorBlendState=&colors; graphics.layout=layout; graphics.renderPass=pass;
        vk_check(vkCreateGraphicsPipelines(device,VK_NULL_HANDLE,1,&graphics,nullptr,&pipeline),"raster graphics pipeline");
        for(auto shader:shaders) vkDestroyShaderModule(device,shader,nullptr);
    }
    void render(VkCommandBuffer command,size_t framebuffer,const MeteorSceneCamera &camera,uint32_t frame) {
        VkClearValue clear[2]{}; clear[0].color={{.035f,.055f,.09f,1}}; clear[1].depthStencil={1,0};
        VkRenderPassBeginInfo begin{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
        begin.renderPass=pass; begin.framebuffer=framebuffers.at(framebuffer); begin.renderArea.extent={width,height};
        begin.clearValueCount=2; begin.pClearValues=clear;
        vkCmdBeginRenderPass(command,&begin,VK_SUBPASS_CONTENTS_INLINE);
        MeteorGpuScene::Parameters p{};
        auto vec=[](float *out,MeteorSceneVec v) { out[0]=v.x; out[1]=v.y; out[2]=v.z; };
        vec(p.origin,camera.origin); vec(p.x,camera.basis_x); vec(p.y,camera.basis_y); vec(p.z,camera.basis_z);
        p.tangents[0]=camera.left; p.tangents[1]=camera.right; p.tangents[2]=camera.up; p.tangents[3]=camera.down;
        p.extent[0]=width; p.extent[1]=height; p.extent[2]=frame;
        vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline);
        vkCmdPushConstants(command,layout,VK_SHADER_STAGE_VERTEX_BIT,0,sizeof(p),&p);
        vkCmdDraw(command,36,26,0,0);
        vkCmdEndRenderPass(command);
    }
    ~MeteorRasterScene() {
        for(auto fb:framebuffers) vkDestroyFramebuffer(device,fb,nullptr);
        vkDestroyPipeline(device,pipeline,nullptr); vkDestroyPipelineLayout(device,layout,nullptr);
        vkDestroyRenderPass(device,pass,nullptr);
        for(auto view:color_views) vkDestroyImageView(device,view,nullptr);
        vkDestroyImageView(device,depth_view,nullptr); vkDestroyImage(device,depth,nullptr); vkFreeMemory(device,depth_memory,nullptr);
    }
};
