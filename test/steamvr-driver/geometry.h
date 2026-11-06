#pragma once
#include <cmath>
#include <cstring>
#include <stdexcept>
namespace meteor_geometry {
inline void projection_raw(const float eye[11],float *left,float *right,float *top,float *bottom) {
    // OpenVR's misleading top/bottom outputs are down/up in OpenXR's Y-up
    // convention. Negating up/down swaps an asymmetric vertical frustum.
    *left=std::tan(eye[7]);*right=std::tan(eye[8]);*top=std::tan(eye[10]);*bottom=std::tan(eye[9]);
}
inline bool valid_pose(const vr::HmdMatrix34_t &m) {
    for(int r=0;r<3;++r)for(int c=0;c<4;++c)if(!std::isfinite(m.m[r][c]))return false;
    for(int a=0;a<3;++a)for(int b=0;b<3;++b) {
        float dot=0;for(int c=0;c<3;++c)dot+=m.m[a][c]*m.m[b][c];
        if(std::abs(dot-(a==b?1.f:0.f))>.01f)return false;
    }
    float determinant=m.m[0][0]*(m.m[1][1]*m.m[2][2]-m.m[1][2]*m.m[2][1])-
        m.m[0][1]*(m.m[1][0]*m.m[2][2]-m.m[1][2]*m.m[2][0])+
        m.m[0][2]*(m.m[1][0]*m.m[2][1]-m.m[1][1]*m.m[2][0]);
    if(std::abs(determinant-1)>.01f)return false;
    return true;
}
inline vr::HmdMatrix34_t compose(const vr::HmdMatrix34_t &a,const vr::HmdMatrix34_t &b) {
    vr::HmdMatrix34_t out{};
    for(int r=0;r<3;++r)for(int c=0;c<4;++c) {out.m[r][c]=c==3?a.m[r][3]:0;for(int k=0;k<3;++k)out.m[r][c]+=a.m[r][k]*b.m[k][c];}
    return out;
}
inline vr::HmdMatrix34_t matrix(const float p[7]) {
    float x=p[3],y=p[4],z=p[5],w=p[6];
    return {{{1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w),p[0]},
             {2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w),p[1]},
             {2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y),p[2]}}};
}
inline void pose(const vr::HmdMatrix34_t &m,float p[7]) {
    if(!valid_pose(m))throw std::runtime_error("Invalid submitted SteamVR pose");
    for(int r=0;r<3;++r)p[r]=m.m[r][3];float trace=m.m[0][0]+m.m[1][1]+m.m[2][2];
    if(trace>0) {float s=std::sqrt(trace+1)*2;p[6]=.25f*s;p[3]=(m.m[2][1]-m.m[1][2])/s;p[4]=(m.m[0][2]-m.m[2][0])/s;p[5]=(m.m[1][0]-m.m[0][1])/s;}
    else {int i=m.m[1][1]>m.m[0][0]?1:0;if(m.m[2][2]>m.m[i][i])i=2;int j=(i+1)%3,k=(i+2)%3;
        float s=std::sqrt(1+m.m[i][i]-m.m[j][j]-m.m[k][k])*2;p[3+i]=.25f*s;p[3+j]=(m.m[j][i]+m.m[i][j])/s;p[3+k]=(m.m[k][i]+m.m[i][k])/s;p[6]=(m.m[k][j]-m.m[j][k])/s;}
}
inline void views(const vr::HmdMatrix34_t heads[2],const float optics[22],float out[22]) {
    for(int eye=0;eye<2;++eye) {pose(compose(heads[eye],matrix(optics+eye*11)),out+eye*11);std::memcpy(out+eye*11+7,optics+eye*11+7,4*sizeof(float));}
}
inline vr::HmdMatrix34_t touch_raw_from_grip(const vr::HmdMatrix34_t &grip,unsigned hand) {
    // Valve oculus_quest2_controller_{left,right}.json: openxr_grip
    // component_local = translation(+/- .007,-.00182941,.1019482)*Rx(20.6deg).
    // Incoming OpenXR pose is world*grip; SteamVR requires world*raw.
    const float a=20.6f*.0174532925199433f,c=std::cos(a),s=std::sin(a);
    const float x=hand==0?.007f:-.007f,y=-.00182941f,z=.1019482f;
    vr::HmdMatrix34_t inverse={{{1,0,0,-x},{0,c,s,-c*y-s*z},{0,-s,c,s*y-c*z}}};
    return compose(grip,inverse);
}
}
