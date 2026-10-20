#pragma once
#include <stdlib.h>
#include <stdio.h>

// Diagnostic-only: object references alone do not stop xrWaitSwapchainImage
// permitting writes to a submitted image. Lease each projection image until its
// multi-compositor slot is discarded/retired, including skipped scheduled slots.
static void meteor_projection_image_lease(const struct xrt_layer_data *data,
                                          struct xrt_swapchain *const *images,
                                          bool retain)
{
    if (!getenv("METEOR_NVENC_BRIDGE") ||
        (data->type != XRT_LAYER_PROJECTION && data->type != XRT_LAYER_PROJECTION_DEPTH)) return;
    if (data->view_count != 2) abort();
    for (uint32_t eye = 0; eye < data->view_count; ++eye) {
        struct xrt_swapchain *sc = images[eye];
        uint32_t index = data->type == XRT_LAYER_PROJECTION_DEPTH ?
            data->depth.v[eye].sub.image_index : data->proj.v[eye].sub.image_index;
        if (!sc || index >= sc->image_count) abort();
        xrt_result_t result = retain ? sc->inc_image_use(sc,index) : sc->dec_image_use(sc,index);
        if (result != XRT_SUCCESS) {
            fprintf(stderr,"METEOR_IMAGE_LEASE_FAILED retain=%d eye=%u index=%u\n",retain,eye,index);
            abort();
        }
        fprintf(stderr,"METEOR_IMAGE_LEASE retain=%d image=%u\n",retain,index);
    }
}
