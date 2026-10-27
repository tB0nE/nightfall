#include "meteor_frame_timestamp.h"
#include <assert.h>
int main(void) {
    const int64_t overlay_source=348558794480372LL;
    const int64_t compositor_now=348559061147028LL;
    assert(compositor_now-overlay_source>250000000);
    assert(meteor_frame_timestamp_new(compositor_now,overlay_source));
    assert(!meteor_frame_timestamp_new(overlay_source,compositor_now));
    assert(!meteor_frame_timestamp_new(compositor_now,compositor_now));
    assert(meteor_frame_timestamp_new(compositor_now+16666666,compositor_now));
    assert(!meteor_frame_timestamp_new(0,0));
    assert(!meteor_frame_timestamp_new(-1,0));
}
