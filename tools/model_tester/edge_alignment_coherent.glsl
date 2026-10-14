#version 430 core
// Local-only Bounded-3: regularize corrections along, not across, depth edges.
in vec2 v_plain;
uniform sampler2D u_depth;
uniform sampler2D u_field;
out vec4 fragColor;
void main() {
    vec2 texel = 1.0/vec2(textureSize(u_depth,0));
    vec4 centre = texture(u_field,v_plain);
    float base = texture(u_depth,v_plain).r;
    if (centre.z <= 0.0001) { fragColor = vec4(base); return; }
    vec2 g = vec2(texture(u_depth,v_plain+vec2(texel.x,0)).r-texture(u_depth,v_plain-vec2(texel.x,0)).r,
                  texture(u_depth,v_plain+vec2(0,texel.y)).r-texture(u_depth,v_plain-vec2(0,texel.y)).r);
    if (length(g) < 0.015) { fragColor = vec4(base); return; }
    vec2 normal = normalize(g);
    // Use adjacent WORKING-grid pixels. Native-grid steps can skip alternating
    // noisy pixels entirely when the working grid is an integer multiple.
    vec2 fieldSize = vec2(textureSize(u_field,0));
    vec2 tangent = normalize(vec2(-normal.y,normal.x)*texel*fieldSize)/fieldSize;
    vec2 total = centre.xy*4.0;
    float weight = 4.0;
    for (int i = -2; i <= 2; ++i) {
        if (i == 0) continue;
        vec4 neighbour = texture(u_field,v_plain+tangent*float(i));
        float spatial = abs(i) == 1 ? 2.0 : 1.0;
        float sameSurface = 1.0-smoothstep(0.02,0.08,abs(neighbour.w-base));
        float agreement = exp(-dot(neighbour.xy-centre.xy,neighbour.xy-centre.xy)*0.5);
        float w = spatial*sameSurface*agreement*smoothstep(0.0,0.15,neighbour.z);
        total += neighbour.xy*w;
        weight += w;
    }
    vec2 correction = mix(centre.xy,total/weight,0.85);
    // Do not introduce tangent motion while averaging different edge normals.
    correction = normal*clamp(dot(correction,normal),-1.5,1.5);
    fragColor = vec4(texture(u_depth,v_plain+correction*texel).r);
}
