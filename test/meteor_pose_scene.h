#pragma once
#include <cmath>
#include <algorithm>
// CPU reference renderer for the tiny diagnostic app only, not the production
// compositor. Fixed world objects make incorrect tracking/eye poses visible.
struct MeteorSceneVec {
    float x,y,z;
    MeteorSceneVec operator+(MeteorSceneVec b) const { return {x+b.x,y+b.y,z+b.z}; }
    MeteorSceneVec operator-(MeteorSceneVec b) const { return {x-b.x,y-b.y,z-b.z}; }
    MeteorSceneVec operator*(float b) const { return {x*b,y*b,z*b}; }
};
inline float meteor_dot(MeteorSceneVec a,MeteorSceneVec b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
inline MeteorSceneVec meteor_cross(MeteorSceneVec a,MeteorSceneVec b) {
    return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};
}
inline MeteorSceneVec meteor_scene(const XrView &view,float u,float v) {
    MeteorSceneVec ray{std::tan(view.fov.angleLeft)*(1-u)+std::tan(view.fov.angleRight)*u,
        std::tan(view.fov.angleUp)*(1-v)+std::tan(view.fov.angleDown)*v,-1};
    const auto &q=view.pose.orientation;
    MeteorSceneVec axis{q.x,q.y,q.z};
    ray=ray+meteor_cross(axis,meteor_cross(axis,ray)+ray*q.w)*2;
    ray=ray*(1/std::sqrt(meteor_dot(ray,ray)));
    const auto &p=view.pose.position; MeteorSceneVec origin{p.x,p.y,p.z};
    float sky=std::clamp(ray.y*.5f+.5f,0.f,1.f);
    MeteorSceneVec color{.03f+.08f*sky,.04f+.12f*sky,.07f+.17f*sky};
    float nearest=1000;
    if(ray.y<-.001f) {
        float t=(-1.5f-origin.y)/ray.y;
        if(t>0 && t<80) {
            MeteorSceneVec hit=origin+ray*t;
            int square=int(std::floor(hit.x))+int(std::floor(hit.z));
            float c=(square%2) ? .20f : .08f; color={c,c,c}; nearest=t;
        }
    }
    const MeteorSceneVec colors[]={{.9f,.18f,.12f},{.12f,.8f,.3f},{.15f,.35f,.95f}};
    for(int i=0;i<3;++i) {
        MeteorSceneVec center{float(i-1)*1.4f,0,-3.f-float(i)*.5f};
        MeteorSceneVec oc=origin-center;
        float b=meteor_dot(oc,ray), d=b*b-meteor_dot(oc,oc)+.36f;
        if(d>0) {
            float t=-b-std::sqrt(d);
            if(t>0 && t<nearest) {
                auto normal=(origin+ray*t-center)*(1/.6f);
                float light=.25f+.75f*std::max(0.f,meteor_dot(normal,{- .4f,.7f,.5f}));
                color=colors[i]*light; nearest=t;
            }
        }
    }
    return color;
}
