#include "meteor_eye_format.h"
#include <assert.h>
int main(void) {
    VkFormat formats[]={VK_FORMAT_R8G8B8A8_UNORM,VK_FORMAT_B8G8R8A8_UNORM,VK_FORMAT_R8G8B8A8_SRGB,VK_FORMAT_B8G8R8A8_SRGB};
    for(int i=0;i<4;++i) {
        assert(meteor_eye_format_valid(formats[i]));
        assert(meteor_eye_format_srgb(formats[i])==(i>=2));
        assert(meteor_eye_format_bgra(formats[i])==(i%2==1));
        for(int j=0;j<4;++j) assert(meteor_eye_formats_compatible(formats[i],formats[j])==((i>=2)==(j>=2)));
    }
    assert(!meteor_eye_format_valid(VK_FORMAT_UNDEFINED));
    assert(!meteor_eye_format_valid(VK_FORMAT_R16G16B16A16_SFLOAT));
    assert(!meteor_eye_formats_compatible(formats[0],VK_FORMAT_D32_SFLOAT));
}
