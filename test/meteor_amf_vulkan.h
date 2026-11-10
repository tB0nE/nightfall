// Monado's half of the Windows AMF path: the texture AMF reads, made writable from Vulkan.
#pragma once
#include "meteor_amf_encoder.h"
#include <vulkan/vulkan.h>
#include <vulkan/vulkan_win32.h>

// A D3D11 texture on the Vulkan GPU's adapter (matched by LUID), imported into Monado's Vulkan
// device: Vulkan writes the packed frame into it and AMF reads it.
struct MeteorAmfVulkanShare {
    Microsoft::WRL::ComPtr<ID3D11Device> d3d;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
    VkDevice device=VK_NULL_HANDLE;
    VkImage image=VK_NULL_HANDLE;
    VkDeviceMemory memory=VK_NULL_HANDLE;
    uint32_t width=0,height=0;
    std::string error;

    bool fail(const std::string &message) { error=message; return false; }

    // Creates the shared texture on the Vulkan GPU's adapter and imports it into `vk_device`.
    bool open(VkPhysicalDevice gpu,VkDevice vk_device,uint32_t w,uint32_t h) {
        width=w; height=h; device=vk_device;
        VkPhysicalDeviceIDProperties id{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
        VkPhysicalDeviceProperties2 props{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2}; props.pNext=&id;
        vkGetPhysicalDeviceProperties2(gpu,&props);
        if(!id.deviceLUIDValid) return fail("Vulkan device has no LUID");
        d3d=meteor_d3d11_on(id.deviceLUID);
        if(!d3d) return fail("No D3D11 device on the Vulkan GPU's adapter");
        D3D11_TEXTURE2D_DESC desc{};
        desc.Width=w; desc.Height=h; desc.MipLevels=desc.ArraySize=1;
        desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM; desc.SampleDesc.Count=1; desc.Usage=D3D11_USAGE_DEFAULT;
        desc.BindFlags=D3D11_BIND_RENDER_TARGET|D3D11_BIND_SHADER_RESOURCE;
        desc.MiscFlags=D3D11_RESOURCE_MISC_SHARED_NTHANDLE|D3D11_RESOURCE_MISC_SHARED;
        if(FAILED(d3d->CreateTexture2D(&desc,nullptr,&texture))) return fail("Cannot create the shared D3D11 texture");
        Microsoft::WRL::ComPtr<IDXGIResource1> shared;
        HANDLE handle=nullptr;
        if(FAILED(texture.As(&shared)) || FAILED(shared->CreateSharedHandle(nullptr,DXGI_SHARED_RESOURCE_READ|DXGI_SHARED_RESOURCE_WRITE,nullptr,&handle)))
            return fail("Cannot share the D3D11 texture");
        const bool imported=import(gpu,handle);
        CloseHandle(handle);  // Vulkan doesn't take ownership of NT handles.
        return imported;
    }

    bool import(VkPhysicalDevice gpu,HANDLE handle) {
        constexpr auto type=VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_BIT;
        VkPhysicalDeviceExternalImageFormatInfo external_info{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO};
        external_info.handleType=type;
        VkPhysicalDeviceImageFormatInfo2 info{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2};
        info.pNext=&external_info; info.format=VK_FORMAT_R8G8B8A8_UNORM; info.type=VK_IMAGE_TYPE_2D;
        info.tiling=VK_IMAGE_TILING_OPTIMAL; info.usage=VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        VkExternalImageFormatProperties external_props{VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES};
        VkImageFormatProperties2 format_props{VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2}; format_props.pNext=&external_props;
        if(vkGetPhysicalDeviceImageFormatProperties2(gpu,&info,&format_props)!=VK_SUCCESS ||
           !(external_props.externalMemoryProperties.externalMemoryFeatures&VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT))
            return fail("The Vulkan driver can't import D3D11 textures");
        VkExternalMemoryImageCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO}; external.handleTypes=type;
        VkImageCreateInfo ici{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; ici.pNext=&external;
        ici.imageType=VK_IMAGE_TYPE_2D; ici.format=VK_FORMAT_R8G8B8A8_UNORM; ici.extent={width,height,1};
        ici.mipLevels=ici.arrayLayers=1; ici.samples=VK_SAMPLE_COUNT_1_BIT; ici.tiling=VK_IMAGE_TILING_OPTIMAL;
        ici.usage=info.usage;
        if(vkCreateImage(device,&ici,nullptr,&image)!=VK_SUCCESS) return fail("Cannot create the imported Vulkan image");
        auto handle_properties=reinterpret_cast<PFN_vkGetMemoryWin32HandlePropertiesKHR>(vkGetDeviceProcAddr(device,"vkGetMemoryWin32HandlePropertiesKHR"));
        if(!handle_properties) return fail("VK_KHR_external_memory_win32 is not enabled");
        VkMemoryWin32HandlePropertiesKHR handle_props{VK_STRUCTURE_TYPE_MEMORY_WIN32_HANDLE_PROPERTIES_KHR};
        if(handle_properties(device,type,handle,&handle_props)!=VK_SUCCESS) return fail("Cannot read the D3D11 texture's memory types");
        VkMemoryRequirements req; vkGetImageMemoryRequirements(device,image,&req);
        const uint32_t bits=req.memoryTypeBits&handle_props.memoryTypeBits;
        if(!bits) return fail("No memory type fits the D3D11 texture");
        uint32_t memory_type=0; while(!(bits&(1u<<memory_type))) ++memory_type;
        VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO}; dedicated.image=image;
        VkImportMemoryWin32HandleInfoKHR import_info{VK_STRUCTURE_TYPE_IMPORT_MEMORY_WIN32_HANDLE_INFO_KHR};
        import_info.pNext=&dedicated; import_info.handleType=type; import_info.handle=handle;
        VkMemoryAllocateInfo mai{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; mai.pNext=&import_info;
        mai.allocationSize=req.size; mai.memoryTypeIndex=memory_type;
        if(vkAllocateMemory(device,&mai,nullptr,&memory)!=VK_SUCCESS) return fail("Cannot import the D3D11 texture into Vulkan");
        if(vkBindImageMemory(device,image,memory,0)!=VK_SUCCESS) return fail("Cannot bind the imported memory");
        return true;
    }

    void destroy() {
        if(image) { vkDestroyImage(device,image,nullptr); image=VK_NULL_HANDLE; }
        if(memory) { vkFreeMemory(device,memory,nullptr); memory=VK_NULL_HANDLE; }
        texture.Reset(); d3d.Reset();
    }
};
