#pragma once
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct meteor_tracking_bridge {
    void *module, *client;
    int (*pose)(void *, int64_t, float *, uint64_t *);
    void (*stop)(void *);
    bool has_optics;
    float eyes[22];
};
static void meteor_tracking_release(struct meteor_tracking_bridge *b) {
    if (b->client && b->stop) b->stop(b->client);
    if (b->module) dlclose(b->module);
    memset(b, 0, sizeof(*b));
}
static bool meteor_tracking_initialize(struct meteor_tracking_bridge *b,struct xrt_device *xdev) {
    const char *pixels=getenv("METEOR_XR_EYE_SIZE");
    if(pixels) {
        if(strcmp(pixels,"256") && strcmp(pixels,"512") && strcmp(pixels,"1024")) return false;
        uint32_t size=(uint32_t)atoi(pixels);
        for(uint32_t eye=0;eye<xdev->hmd->view_count;++eye) {
            xdev->hmd->views[eye].display.w_pixels=size;
            xdev->hmd->views[eye].display.h_pixels=size;
        }
        fprintf(stderr,"METEOR_RECOMMENDED_EYE_SIZE pixels=%u\n",size);
    }
    const char *library = getenv("METEOR_TRACKING_BRIDGE");
    if (!library) return true; // Original simulated device remains diagnostic default.
    const char *port = getenv("METEOR_TRACKING_PORT");
    if (!port) return false;
    b->module = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!b->module) return false;
    void *(*start)(const char *) = NULL;
    void *symbol = dlsym(b->module, "meteor_tracking_start_v1");
    memcpy(&start, &symbol, sizeof(start));
    symbol = dlsym(b->module, "meteor_tracking_pose_v1"); memcpy(&b->pose, &symbol, sizeof(b->pose));
    symbol = dlsym(b->module, "meteor_tracking_stop_v1"); memcpy(&b->stop, &symbol, sizeof(b->stop));
    if (!start || !b->pose || !b->stop || !(b->client = start(port))) {
        meteor_tracking_release(b); return false;
    }
    if(getenv("METEOR_XR_HEADSET_OPTICS")) {
        int (*optics)(void *,float *)=NULL;
        symbol=dlsym(b->module,"meteor_tracking_optics_v1"); memcpy(&optics,&symbol,sizeof(optics));
        if(!optics || !optics(b->client,b->eyes)) { meteor_tracking_release(b); return false; }
        b->has_optics=true;
    }
    return true;
}
static void meteor_tracking_eye_geometry(struct meteor_tracking_bridge *b,struct xrt_device *xdev,
                                         struct xrt_fov *fovs,struct xrt_pose *poses) {
    if(!b->has_optics) return;
    for(int i=0;i<2;++i) {
        const float *v=b->eyes+i*11;
        if(poses) {
            poses[i].position=(struct xrt_vec3){v[0],v[1],v[2]};
            poses[i].orientation=(struct xrt_quat){v[3],v[4],v[5],v[6]};
        }
        struct xrt_fov f={.angle_left=v[7],.angle_right=v[8],.angle_up=v[9],.angle_down=v[10]};
        if(fovs) fovs[i]=f;
        // Device-visible static FOV is initialized once before publication.
        if(!poses && !fovs) xdev->hmd->distortion.fov[i]=f;
    }
}
static bool meteor_tracking_relation(struct meteor_tracking_bridge *b, int64_t at_ns,
                                     struct xrt_space_relation *out) {
    if (!b->client) return false;
    memset(out, 0, sizeof(*out));
    float p[7]; uint64_t stamp = 0;
    if (!b->pose(b->client, at_ns, p, &stamp)) return true; // Explicitly invalid, never simulated fallback.
    out->pose.position = (struct xrt_vec3){p[0],p[1],p[2]};
    out->pose.orientation = (struct xrt_quat){p[3],p[4],p[5],p[6]};
    out->relation_flags = XRT_SPACE_RELATION_ORIENTATION_VALID_BIT | XRT_SPACE_RELATION_POSITION_VALID_BIT |
        XRT_SPACE_RELATION_ORIENTATION_TRACKED_BIT | XRT_SPACE_RELATION_POSITION_TRACKED_BIT;
    fprintf(stderr,"METEOR_TRACKING_APPLIED sample_ns=%llu position=%.6f,%.6f,%.6f\n",
        (unsigned long long)stamp,p[0],p[1],p[2]);
    return true;
}
