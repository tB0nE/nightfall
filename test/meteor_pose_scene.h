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
struct MeteorSceneCamera {
    XrPosef pose;
    float left,right,up,down;
    MeteorSceneVec origin,basis_x,basis_y,basis_z,offsets[3];
    float sphere_terms[3];
    explicit MeteorSceneCamera(const XrView &view) : pose(view.pose),
        left(std::tan(view.fov.angleLeft)),right(std::tan(view.fov.angleRight)),
        up(std::tan(view.fov.angleUp)),down(std::tan(view.fov.angleDown)) {
        const auto &q=pose.orientation; MeteorSceneVec axis{q.x,q.y,q.z};
        auto rotate=[&](MeteorSceneVec v) { return v+meteor_cross(axis,meteor_cross(axis,v)+v*q.w)*2; };
        basis_x=rotate({1,0,0}); basis_y=rotate({0,1,0}); basis_z=rotate({0,0,-1});
        origin={pose.position.x,pose.position.y,pose.position.z};
        for(int i=0;i<3;++i) {
            offsets[i]=origin-MeteorSceneVec{float(i-1)*1.4f,0,-3.f-float(i)*.5f};
            sphere_terms[i]=meteor_dot(offsets[i],offsets[i])-.36f;
        }
    }
};
inline MeteorSceneVec meteor_scene(const MeteorSceneCamera &camera,float u,float v) {
    MeteorSceneVec ray=camera.basis_x*(camera.left*(1-u)+camera.right*u)+
        camera.basis_y*(camera.up*(1-v)+camera.down*v)+camera.basis_z;
    ray=ray*(1/std::sqrt(meteor_dot(ray,ray)));
    MeteorSceneVec origin=camera.origin;
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
        float b=meteor_dot(camera.offsets[i],ray), d=b*b-camera.sphere_terms[i];
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
