#version 430 core
// Experimental local-only boundary relocation. Never used by the headset.
in vec2 v_plain;
uniform sampler2D u_depth;
uniform sampler2D u_guide;
uniform float u_radius;
uniform float u_strength;
out vec4 fragColor;
void unchanged(float base) {
#ifdef BOUNDED3_FIELD
    fragColor = vec4(0.0,0.0,0.0,base);
#else
    fragColor = vec4(base);
#endif
}
void main() {
    vec2 texel = 1.0 / vec2(textureSize(u_depth, 0));
    float base = texture(u_depth, v_plain).r;
    vec2 g = vec2(texture(u_depth, v_plain + vec2(texel.x,0)).r - texture(u_depth, v_plain - vec2(texel.x,0)).r,
                  texture(u_depth, v_plain + vec2(0,texel.y)).r - texture(u_depth, v_plain - vec2(0,texel.y)).r);
    float magnitude = length(g);
    if (magnitude < 0.015 || u_strength == 0.0 || u_radius == 0.0) { unchanged(base); return; }
    // Work in native depth texels, so the bound has a meaningful fixed size.
    vec2 stepUV = normalize(g) * texel;
    float depthSum = 0.0, depthWeight = 0.0;
    for (int i = -4; i <= 4; ++i) {
        float s = float(i) * u_radius / 4.0;
        vec2 q = v_plain + stepUV * s;
        float score = abs(texture(u_depth, q + stepUV * 0.5).r - texture(u_depth, q - stepUV * 0.5).r);
        float w = pow(score, 4.0);
        depthSum += s * w;
        depthWeight += w;
    }
    float depthPosition = depthSum / max(depthWeight, 1e-12);
    float colourSum = 0.0, colourWeight = 0.0, peakColour = 0.0;
#ifdef BOUNDED3_FIELD
    float colourMoment2 = 0.0;
#endif
    for (int i = -4; i <= 4; ++i) {
        float s = float(i) * u_radius / 4.0;
        vec2 q = v_plain + stepUV * s;
        vec3 gx = texture(u_guide, q + vec2(texel.x*0.5,0)).rgb - texture(u_guide, q - vec2(texel.x*0.5,0)).rgb;
        vec3 gy = texture(u_guide, q + vec2(0,texel.y*0.5)).rgb - texture(u_guide, q - vec2(0,texel.y*0.5)).rgb;
        vec3 along = gx * normalize(g).x + gy * normalize(g).y;
        float energy = dot(gx,gx) + dot(gy,gy);
        float orientation = dot(along,along) / max(energy, 1e-8);
        float contrast = length(along);
        float prior = exp(-pow((s-depthPosition)/max(u_radius,0.001),2.0)*2.0);
        float w = pow(contrast,4.0) * smoothstep(0.65,0.9,orientation) * prior;
        colourSum += s*w;
#ifdef BOUNDED3_FIELD
        colourMoment2 += s*s*w;
#endif
        colourWeight += w;
        peakColour = max(peakColour, contrast * smoothstep(0.65,0.9,orientation));
    }
    if (colourWeight < 1e-10) { unchanged(base); return; }
    float colourPosition = colourSum / colourWeight;
    float confidence = smoothstep(0.015,0.06,magnitude) * smoothstep(0.06,0.2,peakColour);
#ifdef BOUNDED3_FIELD
    // Multiple competing peaks, or a broadly uncertain colour boundary: fade
    // back toward linear instead of averaging two unrelated candidate edges.
    float variance = max(colourMoment2/colourWeight-colourPosition*colourPosition,0.0);
    confidence *= 1.0-smoothstep(0.45,1.2,variance);
#endif
    float shift = clamp(depthPosition-colourPosition, -u_radius, u_radius) * confidence * u_strength;
#ifdef BOUNDED3_FIELD
    // Signed native-depth-texel displacement and confidence, NOT an 8-bit map.
    fragColor = vec4(normalize(g)*shift,confidence,base);
#else
    float d = texture(u_depth, v_plain + stepUV*shift).r;
    fragColor = vec4(d);
#endif
}
