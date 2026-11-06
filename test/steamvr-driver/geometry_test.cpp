#include <openvr_driver.h>
#include "geometry.h"
#include <cassert>
#include <cstdio>
#include <limits>
static void near(float a,float b) {assert(std::abs(a-b)<.00002f);}
int main() {
    float optics[22]={-.032f,.006f,.01f,0,.043619387f,0,.99904822f,-.85f,.72f,.81f,-.67f,
                       .032f,.006f,.01f,0,-.043619387f,0,.99904822f,-.72f,.85f,.81f,-.67f};
    unsigned frames=0;
    for(int eye=0;eye<2;++eye) {
        float l,r,t,b;auto f=optics+eye*11;meteor_geometry::projection_raw(f,&l,&r,&t,&b);
        near(std::atan(l),f[7]);near(std::atan(r),f[8]);near(std::atan(b),f[9]);near(std::atan(t),f[10]);
        float scale=2/(b-t),offset=(b+t)/(b-t);
        near((1+offset)/scale,std::tan(f[9]));near((-1+offset)/scale,std::tan(f[10]));
    }
    // Cover both quaternion conversion branches, asymmetric FOV and canted
    // eyes. Check against independent analytic yaw/roll rotation, not another
    // matrix-to-quaternion implementation.
    for(int degrees=-180;degrees<=180;degrees+=3)for(int roll=-30;roll<=30;roll+=15) {
        float yaw=degrees*.0174532925199433f,r=roll*.0174532925199433f;
        float cy=std::cos(yaw),sy=std::sin(yaw),cr=std::cos(r),sr=std::sin(r);
        vr::HmdMatrix34_t head={{{cy*cr,-cy*sr,sy,.2f*sy},{sr,cr,0,1.6f+.1f*cr},{-sy*cr,sy*sr,cy,-.75f}}};
        vr::HmdMatrix34_t heads[2]={head,head};float views[22]{};meteor_geometry::views(heads,optics,views);
        for(int eye=0;eye<2;++eye) {
            const float *local=optics+eye*11,*wire=views+eye*11;
            near(wire[0],head.m[0][3]+cy*cr*local[0]-cy*sr*local[1]+sy*local[2]);
            near(wire[1],head.m[1][3]+sr*local[0]+cr*local[1]);
            near(wire[2],head.m[2][3]-sy*cr*local[0]+sy*sr*local[1]+cy*local[2]);
            auto actual=meteor_geometry::matrix(wire);float eye_yaw=eye==0?.0872664626f:-.0872664626f;
            float ec=std::cos(eye_yaw),es=std::sin(eye_yaw);
            near(actual.m[0][0],cy*cr*ec-sy*es);near(actual.m[0][2],cy*cr*es+sy*ec);
            near(actual.m[1][0],sr*ec);near(actual.m[1][2],sr*es);
            near(actual.m[2][0],-sy*cr*ec-cy*es);near(actual.m[2][2],-sy*cr*es+cy*ec);
            for(int k=7;k<11;++k)near(wire[k],local[k]);
        }
        ++frames;
    }
    // The raw controller followed by Valve's model grip component must recover
    // the original world grip pose for either hand and arbitrary rotations.
    for(unsigned hand=0;hand<2;++hand)for(int degrees=-180;degrees<=180;degrees+=15) {
        float a=degrees*.0174532925199433f;
        float p[7]={.2f,1.3f,-.5f,0,std::sin(a/2),0,std::cos(a/2)};
        auto grip=meteor_geometry::matrix(p),raw=meteor_geometry::touch_raw_from_grip(grip,hand);
        float model[7]={hand==0?.007f:-.007f,-.00182941f,.1019482f,std::sin(20.6f*.0174532925199433f/2),0,0,std::cos(20.6f*.0174532925199433f/2)};
        auto recovered=meteor_geometry::compose(raw,meteor_geometry::matrix(model));
        for(int r=0;r<3;++r)for(int col=0;col<4;++col)near(recovered.m[r][col],grip.m[r][col]);
    }
    std::puts("PASS: both Touch controller grip origins round-trip through Valve model offsets");
    vr::HmdMatrix34_t invalid{};assert(!meteor_geometry::valid_pose(invalid));
    invalid={{{-1,0,0,0},{0,1,0,0},{0,0,1,0}}};assert(!meteor_geometry::valid_pose(invalid));
    invalid={{{1,0,0,0},{0,1,0,0},{0,0,1,0}}};invalid.m[0][3]=std::numeric_limits<float>::quiet_NaN();assert(!meteor_geometry::valid_pose(invalid));
    std::printf("PASS: %u moving-head poses, canted/asymmetric eyes, quaternion round trips and invalid-pose rejection\n",frames);
}
