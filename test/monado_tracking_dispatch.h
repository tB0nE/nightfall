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
};
static void meteor_tracking_release(struct meteor_tracking_bridge *b) {
    if (b->client && b->stop) b->stop(b->client);
    if (b->module) dlclose(b->module);
    memset(b, 0, sizeof(*b));
}
static bool meteor_tracking_initialize(struct meteor_tracking_bridge *b) {
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
    return true;
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
