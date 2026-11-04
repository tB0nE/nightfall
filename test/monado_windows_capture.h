// First Windows capture seam for the pinned Monado null compositor.
// This checks that both submitted OpenXR eye images reach the server, while
// keeping the Windows runtime independent of the Linux encoder bridge.
#pragma once

#include "util/comp_swapchain.h"
#include "xrt/xrt_device.h"
#include "math/m_api.h"
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
        if (accum->layers[i].data.type == XRT_LAYER_PROJECTION ||
            accum->layers[i].data.type == XRT_LAYER_PROJECTION_DEPTH) {
            projection = &accum->layers[i];
            break;
        }
    }
    // Menus can submit only quad layers. They are valid, though this first
    // diagnostic does not compose them yet.
    if (!projection) return true;
    if (projection->data.view_count != 2) return false;
    // Match Linux's colour-only transport for standard apps that also submit
    // composition depth. Keep each colour subimage, pose, FOV and chroma data.
    struct comp_layer colour=*projection;
    if (projection->data.type == XRT_LAYER_PROJECTION_DEPTH) {
        colour.data.type=XRT_LAYER_PROJECTION;
        for (uint32_t eye=0;eye<2;++eye) colour.data.proj.v[eye]=projection->data.depth.v[eye];
        colour.data.proj.chroma_key=projection->data.depth.chroma_key;
        projection=&colour;
    }
    const bool view_space=(projection->data.flags & XRT_LAYER_COMPOSITION_VIEW_SPACE_BIT)!=0;
    const float original_y=(projection->data.proj.v[0].pose.position.y+projection->data.proj.v[1].pose.position.y)*0.5f;
    if(view_space) {
        struct xrt_space_relation head={0};head.pose.orientation.w=1;
        struct xrt_fov fovs[2];struct xrt_pose poses[2];
        struct xrt_vec3 relation={.x=.063f};
        if(xrt_device_get_view_poses(c->xdev,&relation,accum->data.display_time_ns,XRT_VIEW_TYPE_STEREO,2,&head,fovs,poses)!=XRT_SUCCESS) return false;
        if(!(head.relation_flags & XRT_SPACE_RELATION_ORIENTATION_VALID_BIT) ||
           !(head.relation_flags & XRT_SPACE_RELATION_POSITION_VALID_BIT)) return true;
        for(uint32_t eye=0;eye<2;++eye) {
            struct xrt_pose local=projection->data.proj.v[eye].pose;
            math_pose_transform(&head.pose,&local,&colour.data.proj.v[eye].pose);
        }
        colour.data.flags &= ~XRT_LAYER_COMPOSITION_VIEW_SPACE_BIT;
        projection=&colour;
    }
    static int previous_view_space=-1;
    if(previous_view_space!=(int)view_space) {
        fprintf(stderr,"METEOR_WINDOWS_PROJECTION view_space=%d input_y=%.6f output_y=%.6f\n",view_space,original_y,
            (projection->data.proj.v[0].pose.position.y+projection->data.proj.v[1].pose.position.y)*0.5f);
        previous_view_space=(int)view_space;
    }
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
        if (getenv("METEOR_CONTINUOUS_FRAMES") || meteor_captured_green[0] == 255) {
            FILE *done = fopen(meteor_probe_path("capture-complete"), "w");
            if (!done) return false;
            if (getenv("METEOR_CONTINUOUS_FRAMES"))
                fprintf(done,"%lld\n",(long long)projection->data.timestamp);
            if (fclose(done) != 0) return false;
        }
    }
    // Scene measurements acknowledge metadata without GPU-to-CPU readback.
    if (!getenv("METEOR_WINDOWS_PIXEL_PROBE") && getenv("METEOR_CONTINUOUS_FRAMES")) {
        FILE *done=fopen(meteor_probe_path("capture-complete"),"w");
        if (!done) return false;
        fprintf(done,"%lld\n",(long long)projection->data.timestamp);
        if (fclose(done)!=0) return false;
    }
    return true;
}
