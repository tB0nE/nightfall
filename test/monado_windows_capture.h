// First Windows capture seam for the pinned Monado null compositor.
// This checks that both submitted OpenXR eye images reach the server, while
// keeping the Windows runtime independent of the Linux encoder bridge.
#pragma once

#include "util/comp_swapchain.h"
#include "monado_windows_readback.h"
#include "monado_windows_encoder.h"

static bool
meteor_windows_capture_layer(struct null_compositor *c)
{
    const struct comp_layer_accum *accum = &c->base.layer_accum;
    static unsigned reported;
    if (accum->layer_count == 0) {
        if (reported < 3 || reported % 120 == 0)
            fprintf(stderr, "METEOR_WINDOWS_CAPTURE_EMPTY frame=%lld\n", (long long)accum->data.frame_id);
        ++reported;
        return true;
    }
    if (accum->layer_count > XRT_MAX_LAYERS) return false;
    const struct comp_layer *projection = NULL;
    for (uint32_t i = 0; i < accum->layer_count; ++i) {
        if (accum->layers[i].data.type == XRT_LAYER_PROJECTION) {
            projection = &accum->layers[i];
            break;
        }
    }
    // Menus can submit only quad layers. They are valid, though this first
    // diagnostic does not compose them yet.
    if (!projection) return true;
    if (projection->data.view_count != 2) return false;
    for (uint32_t eye = 0; eye < 2; ++eye) {
        const struct xrt_sub_image *sub = &projection->data.proj.v[eye].sub;
        if (!projection->sc_array[eye]) return false;
        const struct comp_swapchain *sc = comp_swapchain(projection->sc_array[eye]);
        if (sub->image_index >= sc->vkic.image_count ||
            sub->array_index >= sc->vkic.info.array_size ||
            sub->rect.offset.w < 0 || sub->rect.offset.h < 0 ||
            sub->rect.extent.w <= 0 || sub->rect.extent.h <= 0 ||
            (uint64_t)sub->rect.offset.w + sub->rect.extent.w > sc->vkic.info.width ||
            (uint64_t)sub->rect.offset.h + sub->rect.extent.h > sc->vkic.info.height ||
            sc->vkic.images[sub->image_index].handle == VK_NULL_HANDLE) return false;
        if (reported < 10 || reported % 120 == 0) {
            fprintf(stderr, "METEOR_WINDOWS_CAPTURE frame=%lld eye=%u image=%u "
                    "format=%u rect=%d,%d,%d,%d layers=%u\n",
                    (long long)accum->data.frame_id, eye, sub->image_index,
                    (unsigned)sc->vkic.info.format, sub->rect.offset.w,
                    sub->rect.offset.h, sub->rect.extent.w, sub->rect.extent.h,
                    accum->layer_count);
        }
    }
    ++reported;
    if (!meteor_windows_encode(c, projection)) return false;
    if (getenv("METEOR_WINDOWS_PIXEL_PROBE")) {
        for (int eye = 0; eye < 2; ++eye) {
            const struct xrt_sub_image *sub = &projection->data.proj.v[eye].sub;
            if (sub->array_index || sub->rect.offset.w || sub->rect.offset.h ||
                !meteor_capture_eye(&c->base.vk, comp_swapchain(projection->sc_array[eye]), sub->image_index, eye)) return false;
        }
        if (meteor_captured_green[0] != meteor_captured_green[1]) return false;
        if (meteor_captured_green[0] == 255) {
            FILE *done = fopen(meteor_probe_path("capture-complete"), "w");
            if (!done) return false;
            if (fclose(done) != 0) return false;
        }
    }
    return true;
}
