#pragma once
// Runs after OpenXR's ordinary layer validation, before IPC submission.
// This is the isolated Meteor runtime's rendering contract, not global Monado.
#include <openxr/openxr.h>
#include <stdlib.h>
#include <math.h>

static const char *meteor_layer_policy(const XrFrameEndInfo *frame)
{
    if (!getenv("METEOR_NVENC_BRIDGE")) return NULL;
    if (frame->layerCount > 128) return "layer_count_exceeds_capture_capacity";
    for (uint32_t i=0; i<frame->layerCount; ++i) {
        const XrCompositionLayerBaseHeader *layer=frame->layers[i];
        if (!layer) return "null_layer";
        switch (layer->type) {
        case XR_TYPE_COMPOSITION_LAYER_PROJECTION: {
            const XrCompositionLayerProjection *projection=(const XrCompositionLayerProjection *)layer;
            if (projection->viewCount!=2) return "only_stereo_projection_supported";
            break;
        }
        case XR_TYPE_COMPOSITION_LAYER_QUAD:
        case XR_TYPE_COMPOSITION_LAYER_EQUIRECT2_KHR:
            break;
        case XR_TYPE_COMPOSITION_LAYER_CYLINDER_KHR: {
            const XrCompositionLayerCylinderKHR *c=(const XrCompositionLayerCylinderKHR *)layer;
            if(isnan(c->radius) || c->radius<0 || !isfinite(c->centralAngle) ||
                c->centralAngle<0 || c->centralAngle>6.283186f ||
                !isfinite(c->aspectRatio) || c->aspectRatio<=0) return "invalid_cylinder_geometry";
            break;
        }
        default:
            return "unsupported_capture_layer_type";
        }
    }
    return NULL;
}
