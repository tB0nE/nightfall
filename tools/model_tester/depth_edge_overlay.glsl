#version 430 core
in vec2 v_plain;
uniform sampler2D u_depth;
uniform sampler2D u_guide;
out vec4 fragColor;
float gradient(vec2 p, vec2 t) {
    return length(vec2(texture(u_depth,p+vec2(t.x,0)).r-texture(u_depth,p-vec2(t.x,0)).r,
                       texture(u_depth,p+vec2(0,t.y)).r-texture(u_depth,p-vec2(0,t.y)).r));
}
void main() {
    vec2 t = 1.0/vec2(textureSize(u_depth,0));
    vec2 outTexel = 1.0/vec2(textureSize(u_guide,0));
    float g = gradient(v_plain,t);
    vec2 normal = normalize(vec2(texture(u_depth,v_plain+vec2(t.x,0)).r-texture(u_depth,v_plain-vec2(t.x,0)).r,
                                 texture(u_depth,v_plain+vec2(0,t.y)).r-texture(u_depth,v_plain-vec2(0,t.y)).r)+vec2(1e-12));
    float ridge = step(gradient(v_plain+normal*outTexel,t),g) * step(gradient(v_plain-normal*outTexel,t),g);
    float alpha = smoothstep(0.015,0.04,g)*ridge*0.9;
    fragColor = vec4(mix(texture(u_guide,v_plain).rgb,vec3(0.0,1.0,0.85),alpha),1.0);
}
