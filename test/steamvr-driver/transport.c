// Reuse the same framing, bounded owned-packet queue, ACKs and END as Monado.
#include "../monado_async_transport.h"
#include "transport.h"
int meteor_steamvr_deliver(uint64_t frame,uint64_t display_ns,uint32_t width,uint32_t height,const float views[22],const uint8_t *bytes,uint32_t length) {
    struct meteor_stereo_encode_v1 input={0};
    input.frame_id=frame;input.display_ns=display_ns;input.eye_size=width;input.eye_height=height;
    memcpy(input.views,views,sizeof(input.views));
    struct meteor_owned_packet packet={0};
    if(!meteor_encoded_copy(&packet,bytes,length))return 0;
    bool ok=meteor_async_enqueue(&input,&packet,getenv("METEOR_XR_DIRECT_PORT"));
    free(packet.bytes);return ok;
}
int meteor_steamvr_finish(void) {return meteor_async_finish();}
