#pragma once
#include <winsock2.h>
#include <windows.h>
#include "monado_nvenc_bridge.h"
#include "monado_direct_transport.h"
#include "monado_async_transport.h"

// Diagnostic projection-only bridge. The caller holds live layer references.
static HMODULE meteor_windows_encoder_module;
static void meteor_windows_log_lifecycle(const char *event)
{
    FILETIME filetime;ULARGE_INTEGER ticks;
    GetSystemTimeAsFileTime(&filetime);ticks.LowPart=filetime.dwLowDateTime;ticks.HighPart=filetime.dwHighDateTime;
    fprintf(stderr,"METEOR_WINDOWS_LIFECYCLE utc_ms=%llu event=%s\n",
        (unsigned long long)((ticks.QuadPart-116444736000000000ULL)/10000),event);
}
static void meteor_windows_encoder_shutdown(void)
{
    if (!meteor_windows_encoder_module) return;
    meteor_windows_log_lifecycle("encoder_shutdown");
    void (*finish)(void) = (void (*)(void))GetProcAddress(meteor_windows_encoder_module, "meteor_encode_finish_v1");
    if (finish) finish();
    bool delivered=getenv("METEOR_XR_ASYNC_DELIVERY") ? meteor_async_finish() : meteor_direct_finish();
    const char *tracking=getenv("METEOR_TRACKING_BRIDGE");
    HMODULE tracking_module=tracking ? GetModuleHandleA(tracking) : NULL;
    if (tracking_module) {
        void (*quiesce)(void)=(void (*)(void))GetProcAddress(tracking_module,"meteor_tracking_quiesce_v1");
        if (quiesce) quiesce();
    }
    if (!delivered) fprintf(stderr,"METEOR_WINDOWS_DELIVERY_FAILED shutdown\n");
    const char *marker=getenv("METEOR_WINDOWS_SESSION_MARKER");
    if (delivered && marker) {
        char ended[4096];
        int length=snprintf(ended,sizeof(ended),"%s.ended",marker);
        if (length>0 && length<(int)sizeof(ended)) {
            FILE *done=fopen(ended,"w"); if (done) fclose(done);
        }
    }
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
        meteor_windows_log_lifecycle("encoder_start");
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
        const struct xrt_layer_projection_view_data *view = &layer->data.proj.v[eye];
        float values[11] = {view->pose.position.x,view->pose.position.y,view->pose.position.z,
            view->pose.orientation.x,view->pose.orientation.y,view->pose.orientation.z,view->pose.orientation.w,
            view->fov.angle_left,view->fov.angle_right,view->fov.angle_up,view->fov.angle_down};
        memcpy(input.views+eye*11,values,sizeof(values));
    }
    const char *port = getenv("METEOR_XR_DIRECT_PORT");
    struct meteor_owned_packet packet = {0};
    if (port) { input.encoded_callback = meteor_encoded_copy; input.callback_context = &packet; }
    vk_queue_lock(vk->main_queue);
    submit(&input);
    vk_queue_unlock(vk->main_queue);
    if (port) {
        bool delivered = getenv("METEOR_XR_ASYNC_DELIVERY") ?
            meteor_async_enqueue(&input,&packet,port) : meteor_direct_send(&input,&packet,port);
        free(packet.bytes);
        if (!delivered) return false;
    }
    last_timestamp = layer->data.timestamp;
    const char *marker = getenv("METEOR_WINDOWS_SESSION_MARKER");
    if (marker && GetFileAttributesA(marker)==INVALID_FILE_ATTRIBUTES) {
        FILE *active=fopen(marker,"w");
        if (!active) return false;
        if (fclose(active)!=0) return false;
    }
    fprintf(stderr, "METEOR_WINDOWS_ENCODE frame=%llu\n", (unsigned long long)input.frame_id);
    return true;
}
