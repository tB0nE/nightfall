// Test-only deterministic tracking bridge. No device or network access.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <chrono>
extern "C" void *meteor_tracking_start_v1(const char *) {return reinterpret_cast<void *>(1);}
extern "C" void meteor_tracking_stop_v1(void *) {}
extern "C" int meteor_tracking_pose_v1(void *,int64_t,float *pose,uint64_t *stamp) {
    const float head[7]={0,1.6f,0,0,0,0,1}; memcpy(pose,head,sizeof(head));
    *stamp=uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count()); return 1;
}
extern "C" int meteor_tracking_controller_v2(unsigned hand,int64_t,float *poses,float *values,
                                              uint32_t *buttons,uint32_t *flags,uint64_t *stamp) {
    unsigned left=0,right=0;
    const char *path=getenv("METEOR_CONTROLLER_FIXTURE");
    FILE *file=path ? fopen(path,"r") : nullptr;
    if(!file) return 0;
    int read=fscanf(file,"%u %u",&left,&right); fclose(file); if(read!=2) return 0;
    memset(poses,0,14*sizeof(float)); poses[6]=poses[13]=1;
    memset(values,0,4*sizeof(float)); *buttons=hand ? right : left; *flags=15;
    *stamp=uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count()); return 1;
}
extern "C" int meteor_tracking_controller_v1(unsigned hand,int64_t at,float *poses,float *values,
                                              uint32_t *flags,uint64_t *stamp) {
    float all[4]; uint32_t buttons;
    int result=meteor_tracking_controller_v2(hand,at,poses,all,&buttons,flags,stamp);
    memcpy(values,all,2*sizeof(float)); return result;
}
