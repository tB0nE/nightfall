#include "meteor_encoder_bitrate.h"
#include <cassert>
#include <initializer_list>
int main() {
    uint32_t bps=0;
    assert(meteor_encoder_bitrate(nullptr,64000000,&bps) && bps==64000000);
    assert(meteor_encoder_bitrate("0",16000000,&bps) && bps==16000000);
    assert(meteor_encoder_bitrate("80",64000000,&bps) && bps==80000000);
    assert(meteor_encoder_bitrate("160",64000000,&bps) && bps==160000000);
    for (auto text : {"7","161","-1","64junk"," 64","42949672960"})
        assert(!meteor_encoder_bitrate(text,64000000,&bps));
}
