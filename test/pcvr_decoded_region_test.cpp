#include "pcvr_decoded_region.h"
#include <cassert>
#include <cmath>
int main() {
    PCVRDecodedRegion region;
    // Exact 115%-Quest-3 HEVC output: logical 4768x2544, padded to 2560 rows.
    assert(pcvr_decoded_region(4768,2560,0,0,4768,2544,4768,2544,region));
    assert(region.uv[0]==0 && region.uv[1]==0 && region.uv[2]==1);
    assert(std::abs(region.uv[3]-.99375f)<1e-6f);
    assert(std::abs((region.uv[1]+region.uv[3])*2560-2544)<.001f);
    // Padding in both dimensions and a non-zero crop origin.
    assert(pcvr_decoded_region(4800,2592,16,32,4784,2576,4768,2544,region));
    assert(std::abs(region.uv[0]*4800-16)<.001f);
    assert(std::abs(region.uv[1]*2592-32)<.001f);
    assert(std::abs((region.uv[0]+region.uv[2]*.5f)*4800-2400)<.001f);
    // No padding leaves texture coordinates unchanged.
    assert(pcvr_decoded_region(4128,2208,0,0,4128,2208,4128,2208,region));
    assert(region.uv[0]==0 && region.uv[1]==0 && region.uv[2]==1 && region.uv[3]==1);
    assert(!pcvr_decoded_region(4768,2560,0,0,4768,2560,4768,2544,region));
    assert(!pcvr_decoded_region(4768,2560,-1,0,4767,2544,4768,2544,region));
    assert(!pcvr_decoded_region(4768,2560,1,0,4769,2544,4768,2544,region));
    assert(!pcvr_decoded_region(0,2560,0,0,4768,2544,4768,2544,region));
    assert(!pcvr_decoded_region(4768,2560,0,0,4768,2544,0,2544,region));
}
