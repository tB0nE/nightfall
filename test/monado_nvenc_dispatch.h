#pragma once
#include "monado_nvenc_bridge.h"
#include "monado_probe_paths.h"
#include "meteor_eye_rect.h"
#include "meteor_eye_format.h"
#include "meteor_frame_timestamp.h"
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
static VkFormat meteor_last_source_formats[2];
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
        memset(meteor_last_source_formats,0,sizeof(meteor_last_source_formats));
    }
}

static bool
meteor_encode_layer_now(struct null_compositor *c, const struct comp_layer *layer, const char *library, uint64_t frame_id,
                       const struct comp_layer *overlays, uint32_t overlay_count,const float *head_pose)
{
    // Multi-compositor can repeat the same submitted layer: don't encode duplicates.
    if(layer->data.timestamp<=0) return false;
    if(!meteor_frame_timestamp_new(layer->data.timestamp,meteor_last_encoded_time)) return true;
    bool first_source=meteor_encoder_module==NULL;
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
        .size = sizeof(input), .layer_abi=METEOR_LAYER_ABI, .layer_stride=sizeof(struct meteor_layer_v2), .instance = vk->instance, .gpu = vk->physical_device,
        .device = vk->device, .queue = vk->main_queue->queue,
        .queue_family = vk->main_queue->family_index,
        .frame_id = frame_id,
        .display_ns = (uint64_t)layer->data.timestamp,
    };
    memcpy(input.head_pose,head_pose,sizeof(input.head_pose));
    struct meteor_layer_v2 quads[METEOR_MAX_QUADS];
    input.quads=quads;
    if(overlay_count>METEOR_MAX_QUADS) return false;
    for(uint32_t i=0;i<overlay_count;++i) {
        const struct xrt_layer_data *data=&overlays[i].data;
        if(data->type==XRT_LAYER_PROJECTION) {
            if(data->view_count!=2 || input.quad_count+2>METEOR_MAX_QUADS) return false;
            input.projection_present=1;
            for(int eye=0;eye<2;++eye) {
                const struct xrt_layer_projection_view_data *view=&data->proj.v[eye];
                const struct xrt_sub_image *sub=&view->sub;
                if(!overlays[i].sc_array[eye]) return false;
                struct comp_swapchain *sc=comp_swapchain(overlays[i].sc_array[eye]);
                if(!meteor_eye_format_valid((VkFormat)sc->vkic.info.format) ||
                    sub->image_index>=sc->vkic.image_count ||
                    (sub->rect.offset.w<0 || sub->rect.offset.h<0 || sub->rect.extent.w<=0 || sub->rect.extent.h<=0 ||
                        (uint64_t)sub->rect.offset.w+sub->rect.extent.w>sc->vkic.info.width || (uint64_t)sub->rect.offset.h+sub->rect.extent.h>sc->vkic.info.height) ||
                    !meteor_eye_slice_valid(sub->array_index,sc->vkic.info.array_size,sc->vkic.info.sample_count)) return false;
                struct meteor_layer_v2 *q=&quads[input.quad_count++];
                *q=(struct meteor_layer_v2){.image=sc->vkic.images[sub->image_index].handle,.format=(VkFormat)sc->vkic.info.format,
                    .width=sc->vkic.info.width,.height=sc->vkic.info.height,.slice=sub->array_index,
                    .rect={sub->rect.offset.w,sub->rect.offset.h,sub->rect.extent.w,sub->rect.extent.h},
                    .pose={view->pose.position.x,view->pose.position.y,view->pose.position.z,
                        view->pose.orientation.x,view->pose.orientation.y,view->pose.orientation.z,view->pose.orientation.w},
                    .color_scale={data->color_scale.r,data->color_scale.g,data->color_scale.b,data->color_scale.a},
                    .color_bias={data->color_bias.r,data->color_bias.g,data->color_bias.b,data->color_bias.a},
                    .flags=(uint32_t)data->flags,.visibility=1u<<eye,.flip_y=data->flip_y,.kind=METEOR_LAYER_PROJECTION,
                    .projection_fov={tanf(view->fov.angle_left),tanf(view->fov.angle_right),tanf(view->fov.angle_up),tanf(view->fov.angle_down)}};
            }
            continue;
        }
        bool panorama=data->type==XRT_LAYER_EQUIRECT2;
        bool cylinder=data->type==XRT_LAYER_CYLINDER;
        if(data->type!=XRT_LAYER_QUAD && !panorama && !cylinder) return false;
        const struct xrt_sub_image *sub=panorama ? &data->equirect2.sub : cylinder ? &data->cylinder.sub : &data->quad.sub;
        uint32_t visibility=panorama ? data->equirect2.visibility : cylinder ? data->cylinder.visibility : data->quad.visibility;
        const struct xrt_pose *pose=panorama ? &data->equirect2.pose : cylinder ? &data->cylinder.pose : &data->quad.pose;
        if(visibility==XRT_LAYER_EYE_VISIBILITY_NONE || (cylinder && data->cylinder.central_angle==0)) continue;
        if(panorama && (!isfinite(data->equirect2.radius) || data->equirect2.radius<0 ||
            !isfinite(data->equirect2.central_horizontal_angle) || data->equirect2.central_horizontal_angle<=0 || data->equirect2.central_horizontal_angle>6.283186f ||
            !isfinite(data->equirect2.upper_vertical_angle) || !isfinite(data->equirect2.lower_vertical_angle) ||
            data->equirect2.upper_vertical_angle<=data->equirect2.lower_vertical_angle ||
            data->equirect2.upper_vertical_angle>1.570797f || data->equirect2.lower_vertical_angle< -1.570797f)) return false;
        if(cylinder && (isnan(data->cylinder.radius) || data->cylinder.radius<0 ||
            !isfinite(data->cylinder.central_angle) || data->cylinder.central_angle<=0 || data->cylinder.central_angle>6.283186f ||
            !isfinite(data->cylinder.aspect_ratio) || data->cylinder.aspect_ratio<=0)) return false;
        if(!overlays[i].sc_array[0]) return false;
        struct comp_swapchain *sc=comp_swapchain(overlays[i].sc_array[0]);
        uint32_t allowed=0x1ff; // Blend, view space, color transform and processing hints.
        if(((uint32_t)data->flags & ~allowed) || !meteor_eye_format_valid((VkFormat)sc->vkic.info.format) ||
            sub->image_index>=sc->vkic.image_count || sub->array_index>=sc->vkic.info.array_size || sc->vkic.info.sample_count!=1 ||
            sub->rect.offset.w<0 || sub->rect.offset.h<0 || sub->rect.extent.w<=0 || sub->rect.extent.h<=0 ||
            (uint64_t)sub->rect.offset.w+sub->rect.extent.w>sc->vkic.info.width ||
            (uint64_t)sub->rect.offset.h+sub->rect.extent.h>sc->vkic.info.height ||
            (!panorama && !cylinder && (!isfinite(data->quad.size.x) || !isfinite(data->quad.size.y) || data->quad.size.x<=0 || data->quad.size.y<=0))) {
            fprintf(stderr,"METEOR_QUAD_REJECT index=%u flags=%u format=%lld rect=%d,%d,%d,%d samples=%u\n",
                i,(unsigned)data->flags,(long long)sc->vkic.info.format,sub->rect.offset.w,sub->rect.offset.h,
                sub->rect.extent.w,sub->rect.extent.h,sc->vkic.info.sample_count);
            return false;
        }
        struct meteor_layer_v2 *q=&quads[input.quad_count++];
        *q=(struct meteor_layer_v2){.image=sc->vkic.images[sub->image_index].handle,.format=(VkFormat)sc->vkic.info.format,
            .width=sc->vkic.info.width,.height=sc->vkic.info.height,.slice=sub->array_index,
            .rect={sub->rect.offset.w,sub->rect.offset.h,sub->rect.extent.w,sub->rect.extent.h},
            .pose={pose->position.x,pose->position.y,pose->position.z,
                   pose->orientation.x,pose->orientation.y,pose->orientation.z,pose->orientation.w},
            .extent={(panorama || cylinder) ? 0 : data->quad.size.x,(panorama || cylinder) ? 0 : data->quad.size.y},
            .color_scale={data->color_scale.r,data->color_scale.g,data->color_scale.b,data->color_scale.a},
            .color_bias={data->color_bias.r,data->color_bias.g,data->color_bias.b,data->color_bias.a},
            .flags=(uint32_t)data->flags,.visibility=visibility,.flip_y=data->flip_y,
            .kind=panorama ? METEOR_LAYER_EQUIRECT2 : cylinder ? METEOR_LAYER_CYLINDER : METEOR_LAYER_QUAD,
            .radius=panorama ? data->equirect2.radius : cylinder && isfinite(data->cylinder.radius) ? data->cylinder.radius : 0,
            .horizontal_angle=panorama ? data->equirect2.central_horizontal_angle : cylinder ? data->cylinder.central_angle : 0,
            .upper_angle=panorama ? data->equirect2.upper_vertical_angle : 0,
            .lower_angle=panorama ? data->equirect2.lower_vertical_angle : 0,
            .aspect_ratio=cylinder ? data->cylinder.aspect_ratio : 0};
    }
    input.eye_size=(uint32_t)layer->data.proj.v[0].sub.rect.extent.w;
    input.eye_height=(uint32_t)layer->data.proj.v[0].sub.rect.extent.h;
    input.background_only=layer->sc_array[0]==NULL;
    if(!input.background_only) input.projection_present=1;
    for (int eye = 0; eye < 2; ++eye) {
        if(!input.background_only) {
        struct comp_swapchain *sc = comp_swapchain(layer->sc_array[eye]);
        uint32_t index = layer->data.proj.v[eye].sub.image_index;
        const struct xrt_rect *rect=&layer->data.proj.v[eye].sub.rect;
        if (index >= sc->vkic.image_count || !meteor_eye_format_valid((VkFormat)sc->vkic.info.format) ||
            !meteor_eye_rect_valid(sc->vkic.info.width,sc->vkic.info.height,rect->offset.w,rect->offset.h,rect->extent.w,rect->extent.h) ||
            (uint32_t)rect->extent.w!=input.eye_size ||
            (uint32_t)rect->extent.h!=input.eye_height ||
            !meteor_eye_slice_valid(layer->data.proj.v[eye].sub.array_index,sc->vkic.info.array_size,sc->vkic.info.sample_count)) {
            return false;
        }
        input.eye_offsets[eye*2]=rect->offset.w; input.eye_offsets[eye*2+1]=rect->offset.h;
        input.eye_slices[eye]=layer->data.proj.v[eye].sub.array_index;
        input.eye_formats[eye]=(VkFormat)sc->vkic.info.format;
        if(first_source) fprintf(stderr,"METEOR_EYE_SOURCE eye=%d array_layers=%u slice=%u\n",eye,sc->vkic.info.array_size,input.eye_slices[eye]);
        input.eyes[eye] = sc->vkic.images[index].handle;
        meteor_last_source_formats[eye]=input.eye_formats[eye];
        } else {
            input.eye_formats[eye]=meteor_last_source_formats[eye] ? meteor_last_source_formats[eye] : VK_FORMAT_R8G8B8A8_UNORM;
            if(!meteor_last_source_formats[eye] && input.quad_count) input.eye_formats[eye]=input.quads[0].format;
            for(uint32_t i=0;i<input.quad_count;++i) if(input.quads[i].kind==METEOR_LAYER_PROJECTION && (input.quads[i].visibility&(1u<<eye))) {
                input.eye_formats[eye]=input.quads[i].format;
                break;
            }
            meteor_last_source_formats[eye]=input.eye_formats[eye];
        }
        const struct xrt_layer_projection_view_data *view = &layer->data.proj.v[eye];
        float values[11] = {view->pose.position.x, view->pose.position.y, view->pose.position.z,
            view->pose.orientation.x, view->pose.orientation.y, view->pose.orientation.z, view->pose.orientation.w,
            view->fov.angle_left, view->fov.angle_right, view->fov.angle_up, view->fov.angle_down};
        memcpy(input.views + eye * 11, values, sizeof(values));
    }
    if(!meteor_eye_formats_compatible(input.eye_formats[0],input.eye_formats[1])) return false;
    if(first_source) fprintf(stderr,"METEOR_STEREO_SOURCE shared_image=%d\n",input.eyes[0]==input.eyes[1]);
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
    fprintf(meta,"{\"source_time_ns\":%lld,",(long long)(overlay_count ? overlays[0].data.timestamp : layer->data.timestamp));
    fprintf(meta, "\"schema\":1,\"projection\":%u,\"frame_id\":%llu,\"display_time_ns\":%lld,\"offset\":%llu,\"bytes\":%llu,\"width\":%u,\"height\":%u,\"views\":[",
        input.projection_present,
        (unsigned long long)input.frame_id, (long long)layer->data.timestamp,
        (unsigned long long)offset, (unsigned long long)bytes,input.eye_size*2,input.eye_height);
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
static bool meteor_encode_layer(struct null_compositor *c,const struct comp_layer *layer,const char *library,
                                const struct comp_layer *overlays,uint32_t overlay_count,const float *head_pose)
{
    uint64_t id=(uint64_t)c->base.layer_accum.data.frame_id;
    return getenv("METEOR_XR_ASYNC_ENCODE") ? meteor_raw_submit(c,layer,library,id,overlays,overlay_count,head_pose) : meteor_encode_layer_now(c,layer,library,id,overlays,overlay_count,head_pose);
}
