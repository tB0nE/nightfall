#pragma once
#include "monado_nvenc_bridge.h"
#include "monado_probe_paths.h"
#include <dlfcn.h>
#include <math.h>
#include <string.h>
#include <sys/stat.h>
static void *meteor_encoder_module;
static meteor_encode_stereo_fn_v1 meteor_encoder_submit;
static void (*meteor_encoder_finish)(void);
static int64_t meteor_last_encoded_time;
static uint64_t meteor_encoded_bytes;

static void meteor_encoder_shutdown(void)
{
    if (meteor_encoder_module) {
        meteor_encoder_finish();
        dlclose(meteor_encoder_module);
        meteor_encoder_module = NULL;
        meteor_last_encoded_time = 0;
        meteor_encoded_bytes = 0;
    }
}

static bool
meteor_encode_layer(struct null_compositor *c, const struct comp_layer *layer, const char *library)
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
        .frame_id = (uint64_t)c->base.layer_accum.data.frame_id,
    };
    for (int eye = 0; eye < 2; ++eye) {
        struct comp_swapchain *sc = comp_swapchain(layer->sc_array[eye]);
        uint32_t index = layer->data.proj.v[eye].sub.image_index;
        if (index >= sc->vkic.image_count || sc->vkic.info.format != VK_FORMAT_R8G8B8A8_UNORM ||
            sc->vkic.info.width != 256 || sc->vkic.info.height != 256 || sc->vkic.info.array_size != 1) {
            meteor_encoder_shutdown(); return false;
        }
        input.eyes[eye] = sc->vkic.images[index].handle;
    }
    input.output_path = meteor_probe_path("monado-stereo.h264");
    // Borrowed queue: serialize all submissions/waits through Monado's own mutex.
    vk_queue_lock(vk->main_queue);
    meteor_encoder_submit(&input);
    vk_queue_unlock(vk->main_queue);
    struct stat output_stat;
    if (stat(input.output_path, &output_stat) != 0 || (uint64_t)output_stat.st_size <= meteor_encoded_bytes) return false;
    uint64_t offset = meteor_encoded_bytes;
    uint64_t bytes = (uint64_t)output_stat.st_size - offset;
    meteor_encoded_bytes += bytes;
    bool continuous = getenv("METEOR_CONTINUOUS_FRAMES") != NULL;
    FILE *meta = fopen(meteor_probe_path(continuous ? "monado-stereo.jsonl" : "monado-stereo.json"), continuous ? "a" : "w");
    if (!meta) return false;
    fprintf(meta, "{\"schema\":1,\"frame_id\":%llu,\"display_time_ns\":%lld,\"offset\":%llu,\"bytes\":%llu,\"width\":512,\"height\":256,\"views\":[",
        (unsigned long long)input.frame_id, (long long)layer->data.timestamp,
        (unsigned long long)offset, (unsigned long long)bytes);
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
