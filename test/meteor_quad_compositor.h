// Local GPU-only projection/quad compositor for the Monado streaming spike.
// Called under Monado's queue mutex. All views live through queue completion.
#pragma once
#include "meteor_quad_math.h"
#include "meteor_quad.vert.h"
#include "meteor_quad.frag.h"

struct MeteorQuadCompositor {
    VkDevice device{};
    VkRenderPass pass{};
    VkImageView target_view{};
    VkFramebuffer framebuffer{};
    VkDescriptorSetLayout descriptors{};
    VkDescriptorPool descriptor_pool{};
    VkPipelineLayout layout{};
    VkPipeline pipeline{};
    VkSampler sampler{};
    std::vector<VkImageView> source_views;
    struct LayerParameters {float color_scale[4],color_bias[4],geometry[4];};
    static_assert(sizeof(LayerParameters)==48,"std430 layer stride");
    VkBuffer parameters{};
    VkDeviceMemory parameter_memory{};
    LayerParameters *mapped_parameters{};
    uint32_t eye_size{};
    uint32_t eye_height{};

    void init(VkPhysicalDevice gpu,VkDevice dev, VkImage target, VkFormat format, uint32_t size,uint32_t height) {
        device=dev; eye_size=size; eye_height=height;
        VkBufferCreateInfo bi{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
        bi.size=sizeof(LayerParameters)*METEOR_MAX_QUADS; bi.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
        VK(vkCreateBuffer(device,&bi,nullptr,&parameters));
        VkMemoryRequirements req{}; vkGetBufferMemoryRequirements(device,parameters,&req);
        VkPhysicalDeviceMemoryProperties memory{}; vkGetPhysicalDeviceMemoryProperties(gpu,&memory);
        uint32_t type=memory.memoryTypeCount;
        for(uint32_t i=0;i<memory.memoryTypeCount;++i)
            if((req.memoryTypeBits&(1u<<i)) && (memory.memoryTypes[i].propertyFlags&
                (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))==
                (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {type=i; break;}
        REQUIRE(type<memory.memoryTypeCount,"No coherent layer metadata memory");
        VkMemoryAllocateInfo ma{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; ma.allocationSize=req.size; ma.memoryTypeIndex=type;
        VK(vkAllocateMemory(device,&ma,nullptr,&parameter_memory));
        VK(vkBindBufferMemory(device,parameters,parameter_memory,0));
        void *mapped=nullptr; VK(vkMapMemory(device,parameter_memory,0,VK_WHOLE_SIZE,0,&mapped));
        mapped_parameters=static_cast<LayerParameters *>(mapped);
        VkAttachmentDescription attachment{};
        attachment.format=format; attachment.samples=VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp=VK_ATTACHMENT_LOAD_OP_LOAD; attachment.storeOp=VK_ATTACHMENT_STORE_OP_STORE;
        attachment.stencilLoadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE; attachment.stencilStoreOp=VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        attachment.finalLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        VkAttachmentReference reference{0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
        VkSubpassDescription subpass{}; subpass.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount=1; subpass.pColorAttachments=&reference;
        VkRenderPassCreateInfo rp{VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO};
        rp.attachmentCount=1; rp.pAttachments=&attachment; rp.subpassCount=1; rp.pSubpasses=&subpass;
        VK(vkCreateRenderPass(device,&rp,nullptr,&pass));
        VkImageViewCreateInfo iv{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
        iv.image=target; iv.viewType=VK_IMAGE_VIEW_TYPE_2D; iv.format=format;
        iv.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        VK(vkCreateImageView(device,&iv,nullptr,&target_view));
        VkFramebufferCreateInfo fb{VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO};
        fb.renderPass=pass; fb.attachmentCount=1; fb.pAttachments=&target_view;
        fb.width=size*2; fb.height=height; fb.layers=1;
        VK(vkCreateFramebuffer(device,&fb,nullptr,&framebuffer));
        VkDescriptorSetLayoutBinding binding[]{
            {0,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,1,VK_SHADER_STAGE_FRAGMENT_BIT,nullptr},
            {1,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1,VK_SHADER_STAGE_FRAGMENT_BIT,nullptr}};
        VkDescriptorSetLayoutCreateInfo dsl{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
        dsl.bindingCount=2; dsl.pBindings=binding;
        VK(vkCreateDescriptorSetLayout(device,&dsl,nullptr,&descriptors));
        VkDescriptorPoolSize pool_size[]{
            {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,METEOR_MAX_QUADS},
            {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,METEOR_MAX_QUADS}};
        VkDescriptorPoolCreateInfo dp{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        dp.maxSets=METEOR_MAX_QUADS; dp.poolSizeCount=2; dp.pPoolSizes=pool_size;
        VK(vkCreateDescriptorPool(device,&dp,nullptr,&descriptor_pool));
        VkPushConstantRange push{VK_SHADER_STAGE_VERTEX_BIT|VK_SHADER_STAGE_FRAGMENT_BIT,0,sizeof(meteor_quad_push)};
        static_assert(sizeof(meteor_quad_push)==128,"Portable Vulkan push constant limit");
        VkPipelineLayoutCreateInfo pl{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
        pl.setLayoutCount=1; pl.pSetLayouts=&descriptors; pl.pushConstantRangeCount=1; pl.pPushConstantRanges=&push;
        VK(vkCreatePipelineLayout(device,&pl,nullptr,&layout));
        VkShaderModuleCreateInfo sm{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};
        VkShaderModule vert{},frag{};
        sm.codeSize=sizeof(meteor_quad_vert); sm.pCode=meteor_quad_vert;
        VK(vkCreateShaderModule(device,&sm,nullptr,&vert));
        sm.codeSize=sizeof(meteor_quad_frag); sm.pCode=meteor_quad_frag;
        VK(vkCreateShaderModule(device,&sm,nullptr,&frag));
        VkPipelineShaderStageCreateInfo shaders[2]{};
        for(auto &s:shaders) { s.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; s.pName="main"; }
        shaders[0].stage=VK_SHADER_STAGE_VERTEX_BIT; shaders[0].module=vert;
        shaders[1].stage=VK_SHADER_STAGE_FRAGMENT_BIT; shaders[1].module=frag;
        VkPipelineVertexInputStateCreateInfo vi{VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
        VkPipelineInputAssemblyStateCreateInfo ia{VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO}; ia.topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        VkPipelineViewportStateCreateInfo vp{VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO}; vp.viewportCount=1; vp.scissorCount=1;
        VkPipelineRasterizationStateCreateInfo rs{VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO};
        rs.polygonMode=VK_POLYGON_MODE_FILL; rs.cullMode=VK_CULL_MODE_NONE; rs.lineWidth=1;
        VkPipelineMultisampleStateCreateInfo ms{VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO}; ms.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT;
        VkPipelineColorBlendAttachmentState blend{}; blend.blendEnable=VK_TRUE;
        blend.srcColorBlendFactor=blend.srcAlphaBlendFactor=VK_BLEND_FACTOR_ONE;
        blend.dstColorBlendFactor=blend.dstAlphaBlendFactor=VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        blend.colorBlendOp=blend.alphaBlendOp=VK_BLEND_OP_ADD; blend.colorWriteMask=15;
        VkPipelineColorBlendStateCreateInfo bs{VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO}; bs.attachmentCount=1; bs.pAttachments=&blend;
        VkDynamicState dynamics[]={VK_DYNAMIC_STATE_VIEWPORT,VK_DYNAMIC_STATE_SCISSOR};
        VkPipelineDynamicStateCreateInfo ds{VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO}; ds.dynamicStateCount=2; ds.pDynamicStates=dynamics;
        VkGraphicsPipelineCreateInfo gp{VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO};
        gp.stageCount=2; gp.pStages=shaders; gp.pVertexInputState=&vi; gp.pInputAssemblyState=&ia;
        gp.pViewportState=&vp; gp.pRasterizationState=&rs; gp.pMultisampleState=&ms; gp.pColorBlendState=&bs;
        gp.pDynamicState=&ds; gp.layout=layout; gp.renderPass=pass;
        VK(vkCreateGraphicsPipelines(device,VK_NULL_HANDLE,1,&gp,nullptr,&pipeline));
        vkDestroyShaderModule(device,vert,nullptr); vkDestroyShaderModule(device,frag,nullptr);
        VkSamplerCreateInfo si{VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO};
        si.magFilter=si.minFilter=VK_FILTER_LINEAR; si.mipmapMode=VK_SAMPLER_MIPMAP_MODE_NEAREST;
        si.addressModeU=si.addressModeV=si.addressModeW=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        VK(vkCreateSampler(device,&si,nullptr,&sampler));
    }

    void clear_views() {
        for(auto v:source_views) vkDestroyImageView(device,v,nullptr);
        source_views.clear();
        VK(vkResetDescriptorPool(device,descriptor_pool,0));
    }

    void record(VkCommandBuffer cmd, const meteor_stereo_encode_v1 &input, VkImage target, uint32_t family) {
        clear_views(); // Previous frame's queue and encoder have completed.
        std::vector<VkDescriptorSet> sets;
        // Import each unique source subresource once. Overlays may share an
        // atlas/image; duplicate EXTERNAL acquisitions would be invalid.
        std::vector<VkImageMemoryBarrier> barriers;
        for(uint32_t i=0;i<input.quad_count;++i) {
            const auto &q=input.quads[i];
            auto &values=mapped_parameters[i];
            for(int k=0;k<4;++k) {values.color_scale[k]=q.color_scale[k]; values.color_bias[k]=q.color_bias[k];}
            values.geometry[0]=q.horizontal_angle;
            values.geometry[1]=q.kind==METEOR_LAYER_CYLINDER ? q.aspect_ratio : q.upper_angle;
            values.geometry[2]=q.lower_angle; values.geometry[3]=q.radius;
            if(q.kind==METEOR_LAYER_PROJECTION) for(int k=0;k<4;++k) values.geometry[k]=q.projection_fov[k];
            VkImageViewCreateInfo iv{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
            iv.image=q.image; iv.viewType=VK_IMAGE_VIEW_TYPE_2D; iv.format=q.format;
            iv.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,q.slice,1};
            VkImageView view{}; VK(vkCreateImageView(device,&iv,nullptr,&view)); source_views.push_back(view);
            VkDescriptorSetAllocateInfo ai{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
            ai.descriptorPool=descriptor_pool; ai.descriptorSetCount=1; ai.pSetLayouts=&descriptors;
            VkDescriptorSet set{}; VK(vkAllocateDescriptorSets(device,&ai,&set)); sets.push_back(set);
            VkDescriptorImageInfo image{sampler,view,VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL};
            VkWriteDescriptorSet write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
            write.dstSet=set; write.dstBinding=0; write.descriptorCount=1; write.descriptorType=VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER; write.pImageInfo=&image;
            VkDescriptorBufferInfo buffer{parameters,0,sizeof(LayerParameters)*METEOR_MAX_QUADS};
            VkWriteDescriptorSet buffer_write{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
            buffer_write.dstSet=set; buffer_write.dstBinding=1; buffer_write.descriptorCount=1;
            buffer_write.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; buffer_write.pBufferInfo=&buffer;
            VkWriteDescriptorSet writes[]={write,buffer_write};
            vkUpdateDescriptorSets(device,2,writes,0,nullptr);
            bool seen=false;
            for(const auto &b:barriers) if(b.image==q.image && b.subresourceRange.baseArrayLayer==q.slice) seen=true;
            if(!seen) {
                VkImageMemoryBarrier b{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
                b.oldLayout=b.newLayout=VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                b.srcQueueFamilyIndex=VK_QUEUE_FAMILY_EXTERNAL; b.dstQueueFamilyIndex=family;
                b.dstAccessMask=VK_ACCESS_SHADER_READ_BIT; b.image=q.image; b.subresourceRange=iv.subresourceRange;
                barriers.push_back(b);
            }
        }
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,0,0,nullptr,0,nullptr,uint32_t(barriers.size()),barriers.data());
        VkImageMemoryBarrier target_barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        target_barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; target_barrier.newLayout=VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        target_barrier.srcQueueFamilyIndex=target_barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
        target_barrier.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;
        target_barrier.dstAccessMask=VK_ACCESS_COLOR_ATTACHMENT_READ_BIT|VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        target_barrier.image=target; target_barrier.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,0,0,nullptr,0,nullptr,1,&target_barrier);
        VkRenderPassBeginInfo begin{VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO};
        begin.renderPass=pass; begin.framebuffer=framebuffer; begin.renderArea.extent={eye_size*2,eye_height};
        vkCmdBeginRenderPass(cmd,&begin,VK_SUBPASS_CONTENTS_INLINE);
        vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline);
        float head[3]; for(int k=0;k<3;++k) head[k]=(input.views[k]+input.views[k+11])*.5f;
        for(uint32_t i=0;i<input.quad_count;++i) {
            const auto &q=input.quads[i];
            meteor_quad_push push{};
            for(int k=0;k<4;++k) { push.color_scale[k]=q.color_scale[k]; push.color_bias[k]=q.color_bias[k]; }
            push.options[0]=q.flags;
            push.options[2]=i;
            push.uv_rect[0]=float(q.rect[0])/q.width;
            push.uv_rect[1]=float(q.rect[1])/q.height;
            push.uv_rect[2]=float(q.rect[2])/q.width;
            push.uv_rect[3]=float(q.rect[3])/q.height;
            if(q.flip_y) { push.uv_rect[1]+=push.uv_rect[3]; push.uv_rect[3]=-push.uv_rect[3]; }
            vkCmdBindDescriptorSets(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,layout,0,1,&sets[i],0,nullptr);
            for(int eye=0;eye<2;++eye) {
                if(!(q.visibility & (1u<<eye))) continue;
                if(q.kind!=METEOR_LAYER_QUAD) {
                    push.options[1]=q.kind;
                    float pose[7]; meteor_layer_world_pose(q.pose,input.head_pose,(q.flags&8)!=0,pose);
                    meteor_panorama_rays(pose,input.views+11*eye,head,false,push.corner,push.color_bias);
                } else {
                    float pose[7]; meteor_layer_world_pose(q.pose,input.head_pose,(q.flags&8)!=0,pose);
                    for(unsigned corner=0;corner<4;++corner) meteor_quad_corner(pose,q.extent,input.views+11*eye,head,false,corner,push.corner[corner]);
                }
                VkViewport viewport{float(eye*eye_size),0,float(eye_size),float(eye_height),0,1};
                VkRect2D scissor{{int32_t(eye*eye_size),0},{eye_size,eye_height}};
                vkCmdSetViewport(cmd,0,1,&viewport); vkCmdSetScissor(cmd,0,1,&scissor);
                vkCmdPushConstants(cmd,layout,VK_SHADER_STAGE_VERTEX_BIT|VK_SHADER_STAGE_FRAGMENT_BIT,0,sizeof(push),&push);
                vkCmdDraw(cmd,6,1,0,0);
            }
        }
        vkCmdEndRenderPass(cmd);
        for(auto &b:barriers) {
            b.srcQueueFamilyIndex=family; b.dstQueueFamilyIndex=VK_QUEUE_FAMILY_EXTERNAL;
            b.srcAccessMask=VK_ACCESS_SHADER_READ_BIT; b.dstAccessMask=0;
        }
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0,0,nullptr,0,nullptr,uint32_t(barriers.size()),barriers.data());
    }

    void destroy() {
        clear_views();
        vkUnmapMemory(device,parameter_memory);
        vkDestroyBuffer(device,parameters,nullptr); vkFreeMemory(device,parameter_memory,nullptr);
        vkDestroySampler(device,sampler,nullptr); vkDestroyPipeline(device,pipeline,nullptr);
        vkDestroyPipelineLayout(device,layout,nullptr); vkDestroyDescriptorPool(device,descriptor_pool,nullptr);
        vkDestroyDescriptorSetLayout(device,descriptors,nullptr); vkDestroyFramebuffer(device,framebuffer,nullptr);
        vkDestroyImageView(device,target_view,nullptr); vkDestroyRenderPass(device,pass,nullptr);
    }
};
