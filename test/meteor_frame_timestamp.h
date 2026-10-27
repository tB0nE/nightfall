#pragma once
#include <stdbool.h>
#include <stdint.h>
// An old/duplicate source frame is normal around independent client/layer
// transitions. Do not submit it to a monotonic video stream or crash on it.
static inline bool meteor_frame_timestamp_new(int64_t timestamp,int64_t previous) {
    return timestamp>0 && timestamp>previous;
}
