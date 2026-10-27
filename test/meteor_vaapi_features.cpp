// Read-only VA encoder feature inventory. No surfaces or encode submissions.
#include <va/va.h>
#include <va/va_drm.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <initializer_list>
int main(int argc,char **argv) {
    if(argc!=2) return 2;
    int fd=open(argv[1],O_RDWR|O_CLOEXEC);if(fd<0) return 2;
    VADisplay display=vaGetDisplayDRM(fd);int major=0,minor=0;
    if(!display || vaInitialize(display,&major,&minor)!=VA_STATUS_SUCCESS) {close(fd);return 1;}
    std::printf("{\"codecs\":{");
    bool first=true;
    for(auto profile:{VAProfileH264Main,VAProfileHEVCMain}) {
        VAConfigAttrib attributes[]={{VAConfigAttribRateControl,0},{VAConfigAttribEncQualityRange,0},
            {VAConfigAttribEncROI,0},{VAConfigAttribEncMaxRefFrames,0},{VAConfigAttribEncMaxSlices,0}};
        if(vaGetConfigAttributes(display,profile,VAEntrypointEncSlice,attributes,5)!=VA_STATUS_SUCCESS) continue;
        VAConfigAttribValEncROI roi{};if(attributes[2].value!=VA_ATTRIB_NOT_SUPPORTED) roi.value=attributes[2].value;
        std::printf("%s\"%s\":{\"rate_control_mask\":%u,\"quality_range\":%u,\"roi_raw\":%u,\"roi_regions\":%u,\"roi_qp_delta\":%u,\"roi_priority\":%u,\"max_refs\":%u,\"max_slices\":%u}",
            first?"":",",profile==VAProfileH264Main?"h264":"hevc",attributes[0].value,attributes[1].value,attributes[2].value,
            roi.bits.num_roi_regions,roi.bits.roi_rc_qp_delta_support,roi.bits.roi_rc_priority_support,attributes[3].value,attributes[4].value);
        first=false;
    }
    std::puts("}}");vaTerminate(display);close(fd);return 0;
}
