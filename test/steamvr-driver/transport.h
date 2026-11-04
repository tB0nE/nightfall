#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int meteor_steamvr_deliver(uint64_t frame,uint64_t display_ns,uint32_t width,uint32_t height,const float views[22],const uint8_t *bytes,uint32_t length);
int meteor_steamvr_finish(void);
#ifdef __cplusplus
}
#endif
