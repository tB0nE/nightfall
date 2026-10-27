#version 450
layout(location=0) in vec3 world;
layout(location=1) flat in vec3 color;
layout(location=2) flat in int floor_surface;
layout(location=0) out vec4 output_color;
void main() {
    vec3 rgb=color;
    if(floor_surface!=0) {
        int square=int(floor(world.x))+int(floor(world.z));
        rgb=vec3((square%2)!=0 ? .22 : .09);
    }
    output_color=vec4(rgb,1);
}
