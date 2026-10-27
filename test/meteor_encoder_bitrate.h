#pragma once
#include <stdint.h>
// Zero/unset preserves historical resolution-dependent bitrate. Reject malformed
// or out-of-range environment values rather than overflowing encoder parameters.
static inline bool meteor_encoder_bitrate(const char *text, uint32_t fallback, uint32_t *bps) {
    if (!text || !*text) { *bps=fallback; return true; }
    uint32_t value=0;
    for (const char *p=text; *p; ++p) {
        if (*p<'0' || *p>'9' || value>160) return false;
        value=value*10+uint32_t(*p-'0');
    }
    if (value && (value<8 || value>160)) return false;
    *bps=value ? value*1000000u : fallback;
    return true;
}
