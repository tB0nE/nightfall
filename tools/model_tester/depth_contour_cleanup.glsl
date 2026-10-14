#version 430 core
// Bounded-4 LOCAL experiment: tangent-only cleanup of Bounded-2 depth.
// No colour texture is used, so cleanup cannot follow text/texture edges.
in vec2 v_plain;
uniform sampler2D u_depth;
out vec4 fragColor;
void main() {
    vec2 t = 1.0/vec2(textureSize(u_depth,0));
    float centre = texture(u_depth,v_plain).r;
    float tl = texture(u_depth,v_plain+vec2(-t.x,-t.y)).r;
    float tc = texture(u_depth,v_plain+vec2(0,-t.y)).r;
    float tr = texture(u_depth,v_plain+vec2(t.x,-t.y)).r;
    float ml = texture(u_depth,v_plain+vec2(-t.x,0)).r;
    float mr = texture(u_depth,v_plain+vec2(t.x,0)).r;
    float bl = texture(u_depth,v_plain+vec2(-t.x,t.y)).r;
    float bc = texture(u_depth,v_plain+vec2(0,t.y)).r;
    float br = texture(u_depth,v_plain+vec2(t.x,t.y)).r;
    vec2 g = vec2(tr+2.0*mr+br-tl-2.0*ml-bl,bl+2.0*bc+br-tl-2.0*tc-tr)*0.25;
    float magnitude = length(g);
    if (magnitude < 0.015) { fragColor = vec4(centre); return; }
    vec2 normal = normalize(g);
    vec2 tangent = vec2(-normal.y,normal.x)*t;
    float lo = min(min(min(tl,tr),min(bl,br)),min(min(tc,bc),min(ml,mr)));
    float hi = max(max(max(tl,tr),max(bl,br)),max(max(tc,bc),max(ml,mr)));
    float minusDepth = texture(u_depth,v_plain-normal*t*2.0).r;
    float plusDepth = texture(u_depth,v_plain+normal*t*2.0).r;
    // Reject narrow ridges/valleys whose two sides return to the same depth.
    float thinGuard = smoothstep(0.4,0.85,abs(plusDepth-minusDepth)/max(hi-lo,1e-5));
    float sum = centre*6.0;
    for (int i = -2; i <= 2; ++i) {
        if (i == 0) continue;
        sum += texture(u_depth,v_plain+tangent*float(i)).r*(abs(i)==1 ? 4.0 : 1.0);
    }
    float gate = smoothstep(0.015,0.06,magnitude)*thinGuard*0.85;
    float delta = clamp(sum/16.0-centre,-min(0.08,magnitude*0.4),min(0.08,magnitude*0.4));
    fragColor = vec4(clamp(centre+gate*delta,lo,hi));
}
