#pragma once
#include <windows.h>
#include "monado_nvenc_bridge.h"

// Diagnostic projection-only bridge. The caller holds live layer references.
static HMODULE meteor_windows_encoder_module;
static void meteor_windows_encoder_shutdown(void)
{
    if (!meteor_windows_encoder_module) return;
    void (*finish)(void) = (void (*)(void))GetProcAddress(meteor_windows_encoder_module, "meteor_encode_finish_v1");
    if (finish) finish();
    FreeLibrary(meteor_windows_encoder_module);
    meteor_windows_encoder_module = NULL;
}
static bool
meteor_windows_encode(struct null_compositor *c, const struct comp_layer *layer)
{
    static meteor_encode_stereo_fn_v1 submit;
    static int64_t last_timestamp;
    if (meteor_windows_encoder_module && layer->data.timestamp <= last_timestamp) return true;
    const char *library = getenv("METEOR_WINDOWS_ENCODER");
    if (!library) return true;
    // This first adapter supports a single opaque projection only.
    if (c->base.layer_accum.layer_count != 1 || layer->data.flip_y ||
        (layer->data.flags & (XRT_LAYER_COMPOSITION_BLEND_TEXTURE_SOURCE_ALPHA_BIT |
                             XRT_LAYER_COMPOSITION_COLOR_BIAS_SCALE))) return false;
    if (!meteor_windows_encoder_module) {
        meteor_windows_encoder_module = LoadLibraryA(library);
        if (!meteor_windows_encoder_module) return false;
        submit = (meteor_encode_stereo_fn_v1)GetProcAddress(meteor_windows_encoder_module, "meteor_encode_stereo_v1");
        if (!submit || !GetProcAddress(meteor_windows_encoder_module, "meteor_encode_finish_v1")) return false;
    }
    struct vk_bundle *vk = &c->base.vk;
    struct meteor_stereo_encode_v1 input = {0};
    input.size = sizeof(input); input.layer_abi = METEOR_LAYER_ABI;
    input.layer_stride = sizeof(struct meteor_layer_v2);
    input.instance = vk->instance; input.gpu = vk->physical_device;
    input.device = vk->device; input.queue = vk->main_queue->queue;
    input.queue_family = vk->main_queue->family_index;
    input.frame_id = c->base.layer_accum.data.frame_id;
    input.display_ns = layer->data.timestamp;
    input.output_path = meteor_probe_path("monado-stereo.h264");
    for (int eye = 0; eye < 2; ++eye) {
        const struct xrt_sub_image *sub = &layer->data.proj.v[eye].sub;
        struct comp_swapchain *sc = comp_swapchain(layer->sc_array[eye]);
        input.eyes[eye] = sc->vkic.images[sub->image_index].handle;
        input.eye_formats[eye] = (VkFormat)sc->vkic.info.format;
        input.eye_slices[eye] = sub->array_index;
        input.eye_offsets[eye*2] = sub->rect.offset.w;
        input.eye_offsets[eye*2+1] = sub->rect.offset.h;
        if (eye && (input.eye_size != (uint32_t)sub->rect.extent.w || input.eye_height != (uint32_t)sub->rect.extent.h)) return false;
        input.eye_size = sub->rect.extent.w; input.eye_height = sub->rect.extent.h;
    }
    vk_queue_lock(vk->main_queue);
    submit(&input);
    vk_queue_unlock(vk->main_queue);
    last_timestamp = layer->data.timestamp;
    fprintf(stderr, "METEOR_WINDOWS_ENCODE frame=%llu\n", (unsigned long long)input.frame_id);
    return true;
}
