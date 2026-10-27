#version 450
layout(push_constant) uniform Camera {
    vec4 origin;
    vec4 basis_x;
    vec4 basis_y;
    vec4 basis_z;
    vec4 tangents;
    uvec4 extent; // width, height, animation frame, reserved
} camera;
layout(location=0) out vec3 world;
layout(location=1) flat out vec3 color;
layout(location=2) flat out int floor_surface;
const vec3 corners[8]=vec3[8](
    vec3(-1,-1,-1),vec3(1,-1,-1),vec3(1,1,-1),vec3(-1,1,-1),
    vec3(-1,-1,1),vec3(1,-1,1),vec3(1,1,1),vec3(-1,1,1));
const int indices[36]=int[36](0,2,1,0,3,2,4,5,6,4,6,7,0,4,7,0,7,3,
    1,2,6,1,6,5,0,1,5,0,5,4,3,7,6,3,6,2);
void main() {
    floor_surface=int(gl_InstanceIndex==25);
    if(floor_surface!=0) {
        const vec2 points[6]=vec2[6](vec2(-12,-.2),vec2(12,-.2),vec2(12,-22),
            vec2(-12,-.2),vec2(12,-22),vec2(-12,-22));
        world=vec3(points[gl_VertexIndex%6].x,-1.5,points[gl_VertexIndex%6].y);
        color=vec3(.28);
    } else {
        int column=gl_InstanceIndex%5, row=gl_InstanceIndex/5;
        float angle=float(camera.extent.z)*.012+float(gl_InstanceIndex)*.27;
        mat3 rotation=mat3(cos(angle),0,-sin(angle), 0,1,0, sin(angle),0,cos(angle));
        vec3 center=vec3(float(column-2)*1.5,-.3+float(row%2)*.35,-2.5-float(row)*1.7);
        world=center+rotation*corners[indices[gl_VertexIndex]]*.36;
        int triangle=(gl_VertexIndex/3)*3;
        vec3 normal=rotation*normalize(cross(corners[indices[triangle+1]]-corners[indices[triangle]],
            corners[indices[triangle+2]]-corners[indices[triangle]]));
        const vec3 colors[5]=vec3[5](vec3(.95,.16,.08),vec3(.1,.85,.3),vec3(.12,.35,1),
            vec3(.95,.65,.08),vec3(.65,.15,.9));
        color=colors[column]*(.35+.65*max(0.0,dot(normal,normalize(vec3(-.4,.7,.5)))));
    }
    vec3 delta=world-camera.origin.xyz;
    float x=dot(delta,camera.basis_x.xyz), y=dot(delta,camera.basis_y.xyz), z=dot(delta,camera.basis_z.xyz);
    float left=camera.tangents.x, right=camera.tangents.y, up=camera.tangents.z, down=camera.tangents.w;
    const float near_plane=.05, far_plane=40;
    gl_Position=vec4((2*x-(right+left)*z)/(right-left),
        ((up+down)*z-2*y)/(up-down),
        far_plane/(far_plane-near_plane)*z-far_plane*near_plane/(far_plane-near_plane),z);
    // Only the first two triangles of the floor instance are needed.
    if(floor_surface!=0 && gl_VertexIndex>=6) gl_Position=vec4(0,0,0,1);
}
