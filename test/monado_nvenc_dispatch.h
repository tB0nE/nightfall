#pragma once
#include "monado_nvenc_bridge.h"
#include "monado_probe_paths.h"
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#include <sys/stat.h>
#include "monado_direct_transport.h"
#include "monado_async_transport.h"
static void *meteor_encoder_module;
static meteor_encode_stereo_fn_v1 meteor_encoder_submit;
static void (*meteor_encoder_finish)(void);
static int64_t meteor_last_encoded_time;
static uint64_t meteor_encoded_bytes;
static bool meteor_raw_finish(void);

static void meteor_encoder_shutdown(void)
{
    if (getenv("METEOR_XR_ASYNC_ENCODE") && !meteor_raw_finish()) fprintf(stderr,"METEOR_CAPTURE_FAILED raw worker drain\n");
    if (meteor_encoder_module) {
        meteor_encoder_finish();
        bool delivered=getenv("METEOR_XR_ASYNC_DELIVERY") ? meteor_async_finish() : meteor_direct_finish();
        if (!delivered) fprintf(stderr, "METEOR_DIRECT_FAILED shutdown\n");
        dlclose(meteor_encoder_module);
        meteor_encoder_module = NULL;
        meteor_last_encoded_time = 0;
        meteor_encoded_bytes = 0;
    }
}

static bool
meteor_encode_layer_now(struct null_compositor *c, const struct comp_layer *layer, const char *library, uint64_t frame_id)
{
    // Multi-compositor can repeat the same submitted layer: don't encode duplicates.
    if (layer->data.timestamp == meteor_last_encoded_time) return true;
    if (layer->data.timestamp < meteor_last_encoded_time) return false;
    void *module = meteor_encoder_module;
    if (!module) module = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!module) { fprintf(stderr, "Encoder bridge load: %s\n", dlerror()); return false; }
    void *symbol = dlsym(module, "meteor_encode_stereo_v1");
    meteor_encode_stereo_fn_v1 encode;
    _Static_assert(sizeof(encode) == sizeof(symbol), "Unsupported dlsym ABI");
    memcpy(&encode, &symbol, sizeof(encode));
    if (!encode) { dlclose(module); return false; }
    symbol = dlsym(module, "meteor_encode_finish_v1");
    memcpy(&meteor_encoder_finish, &symbol, sizeof(meteor_encoder_finish));
    if (!meteor_encoder_finish) { dlclose(module); return false; }
    meteor_encoder_module = module;
    meteor_encoder_submit = encode;
    struct vk_bundle *vk = &c->base.vk;
    struct meteor_stereo_encode_v1 input = {
        .size = sizeof(input), .instance = vk->instance, .gpu = vk->physical_device,
        .device = vk->device, .queue = vk->main_queue->queue,
        .queue_family = vk->main_queue->family_index,
        .frame_id = frame_id,
        .display_ns = (uint64_t)layer->data.timestamp,
    };
    input.eye_size=comp_swapchain(layer->sc_array[0])->vkic.info.width;
    for (int eye = 0; eye < 2; ++eye) {
        struct comp_swapchain *sc = comp_swapchain(layer->sc_array[eye]);
        uint32_t index = layer->data.proj.v[eye].sub.image_index;
        if (index >= sc->vkic.image_count || sc->vkic.info.format != VK_FORMAT_R8G8B8A8_UNORM ||
            (input.eye_size != 256 && input.eye_size != 512) || sc->vkic.info.width != input.eye_size ||
            sc->vkic.info.height != input.eye_size || sc->vkic.info.array_size != 1) {
            return false;
        }
        input.eyes[eye] = sc->vkic.images[index].handle;
        const struct xrt_layer_projection_view_data *view = &layer->data.proj.v[eye];
        float values[11] = {view->pose.position.x, view->pose.position.y, view->pose.position.z,
            view->pose.orientation.x, view->pose.orientation.y, view->pose.orientation.z, view->pose.orientation.w,
            view->fov.angle_left, view->fov.angle_right, view->fov.angle_up, view->fov.angle_down};
        memcpy(input.views + eye * 11, values, sizeof(values));
    }
    struct meteor_owned_packet packet = {0};
    const char *direct_port = getenv("METEOR_XR_DIRECT_PORT");
    if (direct_port) { input.encoded_callback = meteor_encoded_copy; input.callback_context = &packet; }
    input.output_path = meteor_probe_path("monado-stereo.h264");
    // Borrowed queue: serialize all submissions/waits through Monado's own mutex.
    vk_queue_lock(vk->main_queue);
    meteor_encoder_submit(&input);
    vk_queue_unlock(vk->main_queue);
    // Delivery uses owned bytes after NVENC unlock and outside the Vulkan queue lock.
    if (direct_port) {
        bool async=getenv("METEOR_XR_ASYNC_DELIVERY") != NULL;
        uint32_t packet_length=packet.length;
        bool delivered = async ? meteor_async_enqueue(&input,&packet,direct_port) : meteor_direct_send(&input, &packet, direct_port);
        free(packet.bytes);
        if (!delivered) { fprintf(stderr, "METEOR_DIRECT_FAILED frame\n"); return false; }
        fprintf(stderr, "%s frame=%llu bytes=%u\n",async ? "METEOR_ASYNC_QUEUED" : "METEOR_DIRECT_OK", (unsigned long long)input.frame_id, packet_length);
    }
    struct stat output_stat;
    if (stat(input.output_path, &output_stat) != 0 || (uint64_t)output_stat.st_size <= meteor_encoded_bytes) return false;
    uint64_t offset = meteor_encoded_bytes;
    uint64_t bytes = (uint64_t)output_stat.st_size - offset;
    meteor_encoded_bytes += bytes;
    bool continuous = getenv("METEOR_CONTINUOUS_FRAMES") != NULL;
    FILE *meta = fopen(meteor_probe_path(continuous ? "monado-stereo.jsonl" : "monado-stereo.json"), continuous ? "a" : "w");
    if (!meta) return false;
    fprintf(meta, "{\"schema\":1,\"frame_id\":%llu,\"display_time_ns\":%lld,\"offset\":%llu,\"bytes\":%llu,\"width\":%u,\"height\":%u,\"views\":[",
        (unsigned long long)input.frame_id, (long long)layer->data.timestamp,
        (unsigned long long)offset, (unsigned long long)bytes,input.eye_size*2,input.eye_size);
    for (int eye = 0; eye < 2; ++eye) {
        const struct xrt_layer_projection_view_data *view = &layer->data.proj.v[eye];
        fprintf(meta, "%s{\"position\":[%.9g,%.9g,%.9g],\"orientation\":[%.9g,%.9g,%.9g,%.9g],\"fov\":[%.9g,%.9g,%.9g,%.9g]}",
            eye ? "," : "", view->pose.position.x, view->pose.position.y, view->pose.position.z,
            view->pose.orientation.x, view->pose.orientation.y, view->pose.orientation.z, view->pose.orientation.w,
            view->fov.angle_left, view->fov.angle_right, view->fov.angle_up, view->fov.angle_down);
    }
    fprintf(meta, "]}\n");
    if (fclose(meta) != 0) return false;
    FILE *ack = fopen(meteor_probe_path("capture-complete"), "w");
    if (!ack) return false;
    fprintf(ack, "%lld\n", (long long)layer->data.timestamp);
    if (fclose(ack) != 0) return false;
    meteor_last_encoded_time = layer->data.timestamp;
    fprintf(stderr, "METEOR_ENCODE_OK frame=%llu timestamp=%lld eyes=2 readback=none\n",
        (unsigned long long)input.frame_id, (long long)layer->data.timestamp);
    return true;
}

#include "monado_raw_encode_queue.h"
static bool meteor_encode_layer(struct null_compositor *c,const struct comp_layer *layer,const char *library)
{
    uint64_t id=(uint64_t)c->base.layer_accum.data.frame_id;
    return getenv("METEOR_XR_ASYNC_ENCODE") ? meteor_raw_submit(c,layer,library,id) : meteor_encode_layer_now(c,layer,library,id);
}
